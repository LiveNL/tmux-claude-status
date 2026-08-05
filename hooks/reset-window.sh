#!/bin/bash
# Fired on SessionStart.

[ -n "$TMUX" ] || exit 0

LOCKDIR="/tmp/claude-spinner-${TMUX_PANE#%}.lock"

# A live spinner cleans up its own lock once it sees the cleared state below.
# Only sweep the lock when its owner is already gone (crash, SIGKILL, reboot),
# otherwise a new spinner could start alongside the running one.
if [ -d "$LOCKDIR" ]; then
    pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        rm -rf "$LOCKDIR"
    fi
fi

tmux set-option -w -t "$TMUX_PANE" @claude-state ""
tmux set-option -w -t "$TMUX_PANE" @claude-spinner "⬢"
tmux refresh-client -S
