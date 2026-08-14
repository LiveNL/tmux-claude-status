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

[ -n "$TMUX" ] || exit 0

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

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

# Atomic — loser of the race has nothing left to do.
mkdir "$LOCKDIR" 2>/dev/null || exit 0

tmux set-option -w -t "$TMUX_PANE" @claude-spinner "⬢" 2>/dev/null

pane="$TMUX_PANE"
lock="$LOCKDIR"

(
    # Cleanup hangs off EXIT only. A trap on TERM would run the handler and
    # then *resume* the loop, making the spinner unkillable by anything but
    # SIGKILL — so the signal traps exit, which fires the EXIT trap in turn.
    trap 'rm -rf "$lock" 2>/dev/null' EXIT
    trap 'exit 0' INT TERM HUP
    frames=("⬢" "⬡")
    i=0
    # Backstop of 4 hours in case the state option ever wedges on "running".
    # The old 30-minute cap was shorter than real agent runs, so the loop kept
    # quitting under a live session: the tab froze on a half-lit glyph that no
    # longer animated while the state still read "running".
    for (( n = 0; n < 28800; n++ )); do
        sleep 0.5
        # An empty read also covers a pane that has since been closed.
        state=$(tmux show-options -pqv -t "$pane" @claude-pane-state 2>/dev/null)
        case "$state" in
            running|permission) ;;
            *) exit 0 ;;
        esac
        i=$(( 1 - i ))
        tmux set-option -w -t "$pane" @claude-spinner "${frames[$i]}" 2>/dev/null
        tmux refresh-client -S 2>/dev/null
    done
    # Cap reached with the state still "running": nothing is coming back for
    # this pane (killed client, crashed session). Clear it so the tab drops to
    # idle instead of freezing mid-spin forever.
    claude_clear_pane
) </dev/null >/dev/null 2>&1 &

echo $! > "$LOCKDIR/pid" 2>/dev/null
disown

exit 0
