#!/bin/bash
# Fired on PreToolUse, UserPromptSubmit, and PostToolUse.
# Sets the tmux window state to "running" and starts an animated spinner.
#
# PreToolUse and UserPromptSubmit are blocking hooks — Claude pipes JSON to
# stdin. We must drain it BEFORE forking so the background loop never holds
# Claude's pipe open, which would block Claude indefinitely.

cat > /dev/null

[ -n "$TMUX" ] || exit 0

PIDFILE="/tmp/claude-spinner-${TMUX_PANE#%}.pid"

if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
fi

tmux set-option -w -t "$TMUX_PANE" @claude-state "running" 2>/dev/null
tmux set-option -w -t "$TMUX_PANE" @claude-spinner "⬢" 2>/dev/null
tmux refresh-client -S 2>/dev/null

pane="$TMUX_PANE"
frames=("⬢" "⬡")

(
    trap 'kill $(jobs -p) 2>/dev/null' EXIT
    i=0
    while true; do
        sleep 0.5 &
        wait $!
        state=$(tmux show-options -wqv -t "$pane" @claude-state 2>/dev/null)
        [ "$state" = "running" ] || exit 0
        i=$(( 1 - i ))
        tmux set-option -w -t "$pane" @claude-spinner "${frames[$i]}" 2>/dev/null
        tmux refresh-client -S 2>/dev/null
    done
) </dev/null >/dev/null 2>&1 &

echo $! > "$PIDFILE"
disown $!

exit 0
