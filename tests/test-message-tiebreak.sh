#!/bin/bash
# Several conversations in one checkout: only the reply Claude just printed
# tells them apart. The pane showing that text must win; near-identical panes
# must not be guessed at.
HOOKS=/Users/livenl/projects/claude-tmux-hooks/hooks
source "$HOOKS/lib/state.sh"
: "${TMUX:=$(tmux display-message -p '#{socket_path},0,0')}"; export TMUX

tmux kill-session -t tiebreak 2>/dev/null
tmux new-session -d -s tiebreak -x 90 -y 24 -c /tmp
W=$(tmux list-windows -t tiebreak -F '#{window_id}' | head -1)
A=$(tmux list-panes -t "$W" -F '#{pane_id}' | head -1)
tmux split-window -t "$W" -d -c /tmp
B=$(tmux list-panes -t "$W" -F '#{pane_id}' | tail -1)

paint() { tmux send-keys -t "$1" "clear; printf '%s\\n  ? for shortcuts\\n' '$2'" Enter; }
paint "$A" "Refactored the invoicing reconciliation queue for Belgium"
paint "$B" "Deleted the deprecated onboarding wizard translations"
sleep 1

fire() { printf '{"hook_event_name":"Stop","session_id":"sid-%s","last_assistant_message":"%s"}' "$1" "$2" \
    | (cd /tmp && env -u TMUX -u TMUX_PANE bash "$HOOKS/notify.sh"); }

fire one "Refactored the invoicing reconciliation queue for Belgium as agreed."
a=$(TMUX_PANE="$A" claude_pane_state); b=$(TMUX_PANE="$B" claude_pane_state)
[ "$a" = "done" ] && [ -z "$b" ] && echo "ok   message picks the right pane -> A='$a'" \
    || echo "FAIL A='$a' B='$b' (want A=done, B empty)"

[ "$(tmux show-options -pqv -t "$A" @claude-session)" = "sid-one" ] \
    && echo "ok   winner re-stamped with the live id" || echo "FAIL no re-stamp"

tmux set-option -p -u -t "$A" @claude-pane-state; tmux set-option -p -u -t "$A" @claude-session
fire two "Something entirely unrelated to either window here."
a=$(TMUX_PANE="$A" claude_pane_state); b=$(TMUX_PANE="$B" claude_pane_state)
[ -z "$a" ] && [ -z "$b" ] && echo "ok   no match writes nothing" || echo "FAIL A='$a' B='$b' (want both empty)"

tmux kill-session -t tiebreak 2>/dev/null
