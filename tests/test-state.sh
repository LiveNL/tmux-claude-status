#!/bin/bash
# Isolated test of the pane-state aggregate. Runs in its own tmux session.
source /Users/livenl/projects/claude-tmux-hooks/hooks/lib/state.sh

: "${TMUX:=$(tmux display-message -p '#{socket_path},0,0')}"
export TMUX

tmux kill-session -t hooktest 2>/dev/null
tmux new-session -d -s hooktest -x 80 -y 24
WIN=$(tmux list-windows -t hooktest -F '#{window_id}' | head -1)
tmux split-window -t "$WIN" -d

A=""; B=""
while read -r pane; do
    if [ -z "$A" ]; then A="$pane"; else B="$pane"; fi
done < <(tmux list-panes -t "$WIN" -F '#{pane_id}')

win() { tmux show-options -wqv -t "$WIN" @claude-state; }
check() { # label expected
    local got
    got=$(win)
    if [ "$got" = "$2" ]; then echo "ok   $1 -> '${got}'"; else echo "FAIL $1 -> '${got}' (want '$2')"; fi
}

echo "panes: A=$A B=$B win=$WIN"

TMUX_PANE="$A" claude_set_state running
TMUX_PANE="$B" claude_set_state input
check "running beats input" "running"

TMUX_PANE="$A" claude_set_state done
check "input beats done" "input"

TMUX_PANE="$B" claude_set_state permission
check "permission beats done" "permission"

TMUX_PANE="$B" claude_clear_pane
check "cleared pane falls back to sibling" "done"

tmux kill-pane -t "$A"
TMUX_PANE="$B" claude_sync_window
check "dead pane leaves no state" ""

echo "-- activity fingerprint --"
TMUX_PANE="$B" claude_mark_activity tool-start AskUserQuestion
TMUX_PANE="$B" bash -c 'source /Users/livenl/projects/claude-tmux-hooks/hooks/lib/state.sh
  printf "phase=%s tool=%s beat=%s\n" "$(claude_pane_opt @claude-pane-phase)" \
    "$(claude_pane_opt @claude-pane-tool)" "$(claude_pane_opt @claude-pane-beat)"'

tmux kill-session -t hooktest 2>/dev/null
