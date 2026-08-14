#!/bin/bash
# Hooks fired with a scrubbed environment must still find their pane.
HOOKS=/Users/livenl/projects/claude-tmux-hooks/hooks
source "$HOOKS/lib/state.sh"
: "${TMUX:=$(tmux display-message -p '#{socket_path},0,0')}"; export TMUX

tmux kill-session -t boottest 2>/dev/null
tmux new-session -d -s boottest -x 80 -y 24 -c /tmp
WIN=$(tmux list-windows -t boottest -F '#{window_id}' | head -1)
P=$(tmux list-panes -t "$WIN" -F '#{pane_id}' | head -1)
SID="test-sid-0001"
tmux set-option -p -t "$P" @claude-session "$SID"

check() { local got; got=$(tmux show-options -pqv -t "$P" @claude-pane-state)
  [ "$got" = "$2" ] && echo "ok   $1 -> '$got'" || echo "FAIL $1 -> '$got' (want '$2')"; }

# 1. session id lookup, no TMUX/TMUX_PANE in the environment at all
printf '{"hook_event_name":"Stop","session_id":"%s","last_assistant_message":"Shall I continue?"}' "$SID" \
  | env -u TMUX -u TMUX_PANE bash "$HOOKS/notify.sh"
check "resolves pane by session id" "input"

# 2. same for busy-window
printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Bash"}' "$SID" \
  | env -u TMUX -u TMUX_PANE bash "$HOOKS/busy-window.sh"
check "busy-window resolves too" "running"

# 3. unknown session id, unique cwd fallback (pane cwd is /tmp)
tmux set-option -p -u -t "$P" @claude-pane-state
printf '{"hook_event_name":"Stop","session_id":"no-such-sid","last_assistant_message":"Done."}' \
  | (cd /tmp && env -u TMUX -u TMUX_PANE bash "$HOOKS/notify.sh")
check "falls back to unique cwd" "done"

# 4. ambiguous cwd must refuse rather than guess. Case 3 re-stamped the pane
# with its sid, so this needs a fresh unknown id and no stamp to lean on.
tmux split-window -t "$WIN" -d -c /tmp
tmux set-option -p -u -t "$P" @claude-session
tmux set-option -p -u -t "$P" @claude-pane-state
printf '{"hook_event_name":"Stop","session_id":"another-sid","last_assistant_message":"Done."}' \
  | (cd /tmp && env -u TMUX -u TMUX_PANE bash "$HOOKS/notify.sh")
check "ambiguous cwd writes nothing" ""

tmux kill-session -t boottest 2>/dev/null

# 5. two panes in one directory: the one carrying a session id wins
tmux kill-session -t boottest2 2>/dev/null
tmux new-session -d -s boottest2 -x 80 -y 24 -c /tmp
W2=$(tmux list-windows -t boottest2 -F '#{window_id}' | head -1)
A=$(tmux list-panes -t "$W2" -F '#{pane_id}' | head -1)
tmux split-window -t "$W2" -d -c /tmp
B=$(tmux list-panes -t "$W2" -F '#{pane_id}' | tail -1)
tmux set-option -p -t "$B" @claude-session "sid-tiebreak"
printf '{"hook_event_name":"Stop","session_id":"unknown-yet","last_assistant_message":"Done."}' \
  | (cd /tmp && env -u TMUX -u TMUX_PANE bash "$HOOKS/notify.sh")
got=$(tmux show-options -pqv -t "$B" @claude-pane-state)
other=$(tmux show-options -pqv -t "$A" @claude-pane-state)
[ "$got" = "done" ] && [ -z "$other" ] && echo "ok   session-id pane wins the tie -> '$got'" \
  || echo "FAIL tie -> B='$got' A='$other' (want B=done, A empty)"
tmux kill-session -t boottest2 2>/dev/null
