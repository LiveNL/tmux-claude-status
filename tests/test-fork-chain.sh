#!/bin/bash
# Claude forks a conversation into its daemon under a new id while the pane
# still wears the id it was stamped with. The fork's own arguments name the
# transcript it came from, so its hooks can be traced back to that pane.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$HOOKS/lib/session-map.sh"
test_server_start
trap test_server_stop EXIT

PANE=$(t list-panes -t t -F '#{pane_id}' | head -1)
PARENT=aaaaaaaa-1111-1111-1111-111111111111
CHILD=bbbbbbbb-2222-2222-2222-222222222222
GRAND=cccccccc-3333-3333-3333-333333333333
PROJ=/Users/x/.claude/projects/-Users-x-repo

TABLE=$(mktemp); trap 'rm -f "$TABLE"' EXIT
cat > "$TABLE" <<PS
/path/claude --session-id $CHILD --fork-session --resume $PROJ/$PARENT.jsonl
/path/claude --session-id $GRAND --fork-session --resume $PROJ/$CHILD.jsonl
/path/claude --session-id dddddddd-4444-4444-4444-444444444444 --fork-session --resume $PROJ/99999999-9999-9999-9999-999999999999.jsonl
PS

t set-option -p -t "$PANE" @claude-session "$PARENT"

check "the stamped id finds its pane"      "$(claude_pane_of_session "$PARENT" "$TABLE")" "$PANE"
check "a fork resolves to the same pane"   "$(claude_pane_of_session "$CHILD"  "$TABLE")" "$PANE"
check "a fork of a fork does too"          "$(claude_pane_of_session "$GRAND"  "$TABLE")" "$PANE"
check "a fork of nobody stays unresolved"  "$(claude_pane_of_session dddddddd-4444-4444-4444-444444444444 "$TABLE")" ""
check "an unknown id stays unresolved"     "$(claude_pane_of_session 55555555-5555-5555-5555-555555555555 "$TABLE")" ""

# A pane accumulates ids: restarting Claude in it gives the same tab a new
# conversation, while work started under the old one is still reporting.
SECOND=eeeeeeee-5555-5555-5555-555555555555
claude_stamp_session "$PANE" "$SECOND"
check "the first id still resolves"  "$(claude_pane_of_session "$PARENT" "$TABLE")" "$PANE"
check "the second id resolves too"   "$(claude_pane_of_session "$SECOND" "$TABLE")" "$PANE"
check "stamping twice does not duplicate" \
      "$(t show-options -pqv -t "$PANE" @claude-session | tr ' ' '\n' | sort | uniq -d | wc -l | tr -d ' ')" "0"
