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

# Env probe: a session was seen running these hooks while none of its tmux
# writes landed. Logs only while the file exists — delete it to switch off.
[ -f /tmp/claude-hook-env.log ] && \
    printf '%s busy   pane=%s tmux=%s ppid=%s cwd=%s\n' "$(date +%H:%M:%S)" "${TMUX_PANE:-UNSET}" "${TMUX:-UNSET}" "$PPID" "$PWD" \
    >> /tmp/claude-hook-env.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

# Resolves TMUX/TMUX_PANE when the session fired this with a scrubbed env.
claude_bootstrap "$payload" || exit 0

LOCKDIR="/tmp/claude-spinner-${TMUX_PANE#%}.lock"

event=""
tool=""
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    IFS=$'\t' read -r event tool < <(
        printf '%s' "$payload" | jq -r '[.hook_event_name // "", .tool_name // ""] | @tsv' 2>/dev/null
    )
fi

case "$event" in
    UserPromptSubmit) phase="prompt" ;;
    PostToolUse)      phase="tool-end" ;;
    *)                phase="tool-start" ;;
esac

claude_mark_activity "$phase" "$tool"
claude_set_state "running"

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

claude_start_spinner "$TMUX_PANE"

exit 0
