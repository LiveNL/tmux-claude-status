#!/bin/bash
# Fired on PreToolUse, UserPromptSubmit, and PostToolUse.
# Sets the tmux window state to "running" and keeps one animated spinner alive.
#
# PreToolUse and UserPromptSubmit are blocking hooks — Claude pipes JSON to
# stdin. We must drain it BEFORE forking so the background loop never holds
# Claude's pipe open, which would block Claude indefinitely.
#
# Parallel tool calls fire this hook concurrently. A read-then-write pidfile
# loses that race and leaks an immortal spinner per call, each forking tmux
# 3x/sec — enough to wedge the single-threaded tmux server overnight. The
# lock directory below is created atomically, so exactly one spinner per pane
# can ever exist; every other invocation just updates state and exits.

cat > /dev/null

[ -n "$TMUX" ] || exit 0

LOCKDIR="/tmp/claude-spinner-${TMUX_PANE#%}.lock"

tmux set-option -w -t "$TMUX_PANE" @claude-state "running" 2>/dev/null
tmux refresh-client -S 2>/dev/null

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
    # Hard cap of 30 min. Backstop in case the state option ever wedges on
    # "running" — a stuck spinner must not outlive the session again.
    for (( n = 0; n < 3600; n++ )); do
        sleep 0.5
        state=$(tmux show-options -wqv -t "$pane" @claude-state 2>/dev/null)
        case "$state" in
            running|permission) ;;
            *) exit 0 ;;
        esac
        i=$(( 1 - i ))
        tmux set-option -w -t "$pane" @claude-spinner "${frames[$i]}" 2>/dev/null
        tmux refresh-client -S 2>/dev/null
    done
) </dev/null >/dev/null 2>&1 &

echo $! > "$LOCKDIR/pid" 2>/dev/null
disown

exit 0
