#!/bin/bash
# Deriving which conversation runs in a pane, from the process arguments and
# the transcripts on disk. No tmux involved.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$HOOKS/lib/session-map.sh"

WORK=$(mktemp -d)
export CLAUDE_PROJECTS="$WORK/projects"
CWD="$WORK/repo"
mkdir -p "$CWD" "$(claude_project_dir "$CWD")"
DIR=$(claude_project_dir "$CWD")
trap 'rm -rf "$WORK"' EXIT

OLD=11111111-1111-1111-1111-111111111111
NEW=22222222-2222-2222-2222-222222222222
OTHER=33333333-3333-3333-3333-333333333333

printf '{"sessionId":"%s"}\n' "$OLD"   > "$DIR/$OLD.jsonl"
printf '{"sessionId":"%s"}\n' "$OTHER" > "$DIR/$OTHER.jsonl"
sleep 1
# The live session quotes the conversation it resumed.
printf '{"sessionId":"%s"}\n{"resumedFrom":"%s"}\n' "$NEW" "$OLD" > "$DIR/$NEW.jsonl"

# A stand-in that keeps running whatever arguments it is handed, so the
# arguments survive in the process table. `sleep` exits on an unknown flag,
# which made every derivation return nothing for the wrong reason.
BIN="$WORK/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nsleep 30\n' > "$BIN/claude"; chmod +x "$BIN/claude"

start() { "$BIN/claude" "$@" >/dev/null 2>&1 & echo $!; }

pid=$(start --resume "$OLD")
check "resumed session resolves to the live transcript" "$(claude_session_of_pane "$pid" "$CWD")" "$NEW"
kill "$pid" 2>/dev/null

pid=$(start --session-id "$OTHER")
check "explicit --session-id wins outright" "$(claude_session_of_pane "$pid" "$CWD")" "$OTHER"
kill "$pid" 2>/dev/null

pid=$(start)
check "a session with no id yields nothing" "$(claude_session_of_pane "$pid" "$CWD")" ""
kill "$pid" 2>/dev/null

pid=$(start --resume 99999999-9999-9999-9999-999999999999)
check "an unknown conversation yields nothing" "$(claude_session_of_pane "$pid" "$CWD")" ""
kill "$pid" 2>/dev/null
