#!/bin/bash
# Fired on SessionStart.

# Drain stdin first: Claude pipes the payload in and holds the write end open
# until it is consumed.
payload=$(cat 2>/dev/null)

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

claude_bootstrap "$payload" || exit 0

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

# A session that has just started is, by definition, waiting on you — so it
# gets the same indicator as one that has finished answering. Leaving it blank
# meant a restored or freshly opened tab showed nothing at all until the first
# prompt, which reads as "no session here".
#
# Only this pane is touched. A sibling pane running its own session keeps its
# state, and the window indicator falls back to whichever is more urgent.
claude_mark_activity "session-start" ""
claude_set_state "input"
tmux set-option -w -t "$TMUX_PANE" @claude-spinner "⬢"
tmux refresh-client -S
