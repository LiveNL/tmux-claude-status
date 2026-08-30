#!/bin/bash
# Fired on PreToolUse, UserPromptSubmit, and PostToolUse.
# Sets the pane state to "running" and keeps one animated spinner alive.
#
# PreToolUse and UserPromptSubmit are blocking hooks — Claude pipes JSON to
# stdin. We must drain it BEFORE forking so the background loop never holds
# Claude's pipe open, which would block Claude indefinitely. The payload is
# kept: hook_event_name decides how much of a park the event may release, and
# it plus tool_name become the activity fingerprint notify.sh reads.
#
# Parallel tool calls fire this hook concurrently. A read-then-write pidfile
# loses that race and leaks an immortal spinner per call, each forking tmux
# 3x/sec — enough to wedge the single-threaded tmux server overnight. The
# lock directory below is created atomically, so exactly one spinner per pane
# can ever exist; every other invocation just updates state and exits.

payload=$(cat 2>/dev/null)
_sid=$(printf %s "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

# Env probe: a session was seen running these hooks while none of its tmux
# writes landed. Logs only while the file exists — delete it to switch off.
[ -f /tmp/claude-hook-env.log ] && {
    _anc=""; _p=$PPID
    for _ in 1 2 3 4; do
        _line=$(ps -p "$_p" -o ppid=,comm= 2>/dev/null) || break
        _anc="$_anc <- $(printf '%s' "$_line" | awk '{print $2}' | xargs basename 2>/dev/null)"
        _p=$(printf '%s' "$_line" | awk '{print $1}')
        [ -z "$_p" ] || [ "$_p" = "1" ] && break
    done
    printf '%s %s pane=%s tmux=%s sid=%s cwd=%s anc=%s\n' "$(date +%H:%M:%S)" "busy  " "${TMUX_PANE:-UNSET}" "${TMUX:+set}" "$_sid" "$PWD" "$_anc" >> /tmp/claude-hook-env.log
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

# Resolves TMUX/TMUX_PANE when the session fired this with a scrubbed env.
claude_bootstrap "$payload" || exit 0

LOCKDIR="/tmp/claude-spinner-${TMUX_PANE#%}.lock"

event=""
tool=""
transcript=""
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    # The transcript rides along so the spinner can notice an interrupt: Esc
    # fires no hook of its own, and the transcript is where it lands.
    #
    # One field per line, one read each. A tab-separated row cannot be split
    # safely here: tab is IFS whitespace, so bash collapses the empty tool_name
    # of a UserPromptSubmit and every field after it shifts left — the pane then
    # records a transcript path as the tool it is running, and nothing carries
    # the transcript at all.
    {
        IFS= read -r event
        IFS= read -r tool
        IFS= read -r transcript
    } < <(printf '%s' "$payload" \
            | jq -r '.hook_event_name // "", .tool_name // "", .transcript_path // ""' 2>/dev/null)
fi

case "$event" in
    UserPromptSubmit)      phase="prompt" ;;
    PostToolUse)           phase="tool-end" ;;
    # Compacting is minutes of work with no tool boundary in it. Without a
    # phase of its own the run looked stalled to notify.sh's staleness check,
    # which would then believe the next idle notification and go amber mid-run.
    PreCompact|PostCompact) phase="compact" ;;
    *)                     phase="tool-start" ;;
esac

claude_mark_activity "$phase" "$tool"

# Some tools are the waiting. A question or a plan put to you blocks on your
# answer — the tab used to spin for as long as you took to read it, until the
# idle notification a minute later finally corrected it. The tool name says so
# outright.
#
# "Nothing else fires until you answer" turned out to be false: subagents and
# background commands keep firing hooks against this same pane, and every one
# of them repainted the tab teal under an unanswered question. So the question
# sets a latch rather than just a state, and claude_set_state keeps the tab
# amber until something retires it — the answer, a new prompt, or Stop.
case "$event:$tool" in
    PreToolUse:AskUserQuestion|PreToolUse:ExitPlanMode)
        claude_set_ask "$tool"
        claude_set_state "input"
        ;;
    PostToolUse:AskUserQuestion|PostToolUse:ExitPlanMode)
        # Answering is you, talking to the chat itself — as much a live turn as
        # typing a prompt — so it releases both holds.
        claude_clear_ask
        claude_clear_settled
        claude_set_state "running"
        ;;
    *)
        # Typing a prompt starts a turn: it retires a latched question — Esc on
        # one leaves no PostToolUse behind — and releases the colour the last
        # turn settled on. Every other event has to take the pane as it finds
        # it, because it may well be a subagent's and not the chat's at all.
        if [ "$event" = "UserPromptSubmit" ]; then
            claude_clear_ask
            claude_clear_settled
        fi
        claude_set_state "running"
        ;;
esac

# Ask the pane what it ended up as rather than what was requested: a question
# or a settled turn may have refused the running above, and neither animates.
[ "$(claude_pane_state)" = "running" ] && want_spinner=1

# A prompt or tool call is proof the conversation resumed, so release an
# auto-park right here — the Claude TUI runs on the alternate screen, where
# output never reaches the stale detector's fingerprint, and a sweep would
# lag up to a minute behind. The park engine is optional kit; without it this
# is a no-op.
#
# A hand-park (@park=1) releases only on UserPromptSubmit: typing a prompt is
# you working in that window. Pre/PostToolUse also fire for a run that was
# already going when the window was parked — releasing on those would make it
# impossible to park a window while Claude is busy in it.
PARK="$HOME/.config/tmux/scripts/tmux-park.sh"
if [ -x "$PARK" ]; then
    park_kind=$(tmux show-options -wqv -t "$TMUX_PANE" @park 2>/dev/null)
    release=""
    case "$park_kind" in
        auto) release=1 ;;
        ?*)   [ "$event" = "UserPromptSubmit" ] && release=1 ;;
    esac
    if [ -n "$release" ]; then
        IFS=$'\t' read -r session window < <(tmux display-message -p -t "$TMUX_PANE" $'#{session_name}\t#{window_id}')
        "$PARK" unpark "$session" "$window" >/dev/null 2>&1
    fi
fi

[ -n "$want_spinner" ] && claude_start_spinner "$TMUX_PANE" "$transcript"

exit 0

exit 0
