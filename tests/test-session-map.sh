#!/bin/bash
# What a pane may claim about its session comes from the process itself.
# Nothing is inferred from transcript contents: a conversation is quoted in
# other transcripts too, and matching on that handed panes a neighbour's id.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$HOOKS/lib/session-map.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nsleep 30\n' > "$BIN/claude"; chmod +x "$BIN/claude"
start() { "$BIN/claude" "$@" >/dev/null 2>&1 & echo $!; }

SID=33333333-3333-3333-3333-333333333333

pid=$(start --session-id "$SID")
check "a process naming its session is believed" "$(claude_session_of_pane "$pid")" "$SID"
kill "$pid" 2>/dev/null

pid=$(start --resume 11111111-1111-1111-1111-111111111111)
check "a resumed id is not the live session" "$(claude_session_of_pane "$pid")" ""
kill "$pid" 2>/dev/null

pid=$(start)
check "no arguments, no claim" "$(claude_session_of_pane "$pid")" ""
kill "$pid" 2>/dev/null
