#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT
# A hook writes to the pane it names, or to nothing at all.
#
# Background and forked sessions run under the daemon and fire the same events
# with no TMUX_PANE. Those used to be attributed to a pane by inference, which
# let an agent drive a tab it does not own.

t kill-session -t stricttest 2>/dev/null
t new-session -d -s stricttest -x 80 -y 24 -c /tmp
W=$(t list-windows -t stricttest -F '#{window_id}' | head -1)
A=$(t list-panes -t "$W" -F '#{pane_id}' | head -1)
t split-window -t "$W" -d -c /tmp
B=$(t list-panes -t "$W" -F '#{pane_id}' | tail -1)

stop='{"hook_event_name":"Stop","session_id":"s","last_assistant_message":"Done."}'
states() { printf 'A=%s B=%s' "$(claude_pane_state "$A")" "$(claude_pane_state "$B")"; }

# 1. no pane in the environment: an agent, not a tab
printf '%s' "$stop" | env -u TMUX_PANE bash "$HOOKS/notify.sh"
[ -z "$(claude_pane_state "$A")$(claude_pane_state "$B")" ] \
    && echo "ok   hook without a pane writes nothing" || echo "FAIL $(states)"

# 2. same for the busy hook, which runs far more often
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' | env -u TMUX_PANE bash "$HOOKS/busy-window.sh"
[ -z "$(claude_pane_state "$A")$(claude_pane_state "$B")" ] \
    && echo "ok   busy hook without a pane writes nothing" || echo "FAIL $(states)"

# 3. a pane id that no longer exists
printf '%s' "$stop" | TMUX_PANE=%99999 bash "$HOOKS/notify.sh"
[ -z "$(claude_pane_state "$A")$(claude_pane_state "$B")" ] \
    && echo "ok   dead pane id writes nothing" || echo "FAIL $(states)"

# 4. a real pane: exactly that one moves
printf '%s' "$stop" | TMUX_PANE="$A" bash "$HOOKS/notify.sh"
[ "$(claude_pane_state "$A")" = "done" ] && [ -z "$(claude_pane_state "$B")" ] \
    && echo "ok   named pane is the only one written" || echo "FAIL $(states)"

# 5. the window shows it, and the sibling pane cannot erase it
printf '%s' "$stop" | TMUX_PANE="$B" bash "$HOOKS/notify.sh"
[ "$(t show-options -wqv -t "$W" @claude-state)" = "done" ] \
    && echo "ok   window reflects the panes" || echo "FAIL window=$(t show-options -wqv -t "$W" @claude-state)"

# 6. A hook from a daemon-owned background process: no pane in its environment,
# but the pane carries the same session id, so it lands exactly there.
SID=44444444-4444-4444-4444-444444444444
t set-option -p -t "$A" @claude-session "$SID"
t set-option -p -u -t "$A" @claude-pane-state
printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Bash"}' "$SID" \
    | env -u TMUX_PANE bash "$HOOKS/busy-window.sh"
check "session id finds the pane when the env cannot" "$(claude_pane_state "$A")" "running"

# 7. An id belonging to no pane — a forked or background conversation — is
# still nobody's tab.
t set-option -p -u -t "$A" @claude-pane-state
t set-option -p -u -t "$B" @claude-pane-state
printf '{"hook_event_name":"PreToolUse","session_id":"deadbeef-0000-0000-0000-000000000000","tool_name":"Bash"}' \
    | env -u TMUX_PANE bash "$HOOKS/busy-window.sh"
check "an unstamped session stays off the tabs" "$(claude_pane_state "$A")$(claude_pane_state "$B")" ""
