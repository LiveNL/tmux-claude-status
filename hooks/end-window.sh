#!/bin/bash
# Fired on SessionEnd.
#
# A session that quits mid-run — /exit, ctrl-c ctrl-c, a crash — fires no Stop.
# Its last state was "running", and the pane it ran in usually survives it (you
# are back at a shell prompt in the same window), so the tab kept spinning over
# a session that no longer exists until something else happened to that pane.
# Nothing else was ever going to happen to that pane.
#
# Clearing is right rather than "done": nothing finished, there is no answer
# waiting, and a sibling pane still running its own session keeps the tab.

# Drain stdin first: Claude pipes the payload in and holds the write end open
# until it is consumed.
payload=$(cat 2>/dev/null)

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

claude_bootstrap "$payload" || exit 0

claude_clear_pane

exit 0
