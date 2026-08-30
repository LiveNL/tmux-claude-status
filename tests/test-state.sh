#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT
# Isolated test of the pane-state aggregate. Runs in its own t session.

export TMUX

t kill-session -t hooktest 2>/dev/null
t new-session -d -s hooktest -x 80 -y 24
WIN=$(t list-windows -t hooktest -F '#{window_id}' | head -1)
t split-window -t "$WIN" -d

A=""; B=""
while read -r pane; do
    if [ -z "$A" ]; then A="$pane"; else B="$pane"; fi
done < <(t list-panes -t "$WIN" -F '#{pane_id}')

win() { t show-options -wqv -t "$WIN" @claude-state; }
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

t kill-pane -t "$A"
TMUX_PANE="$B" claude_sync_window
check "dead pane leaves no state" ""

echo "-- activity fingerprint --"
TMUX_PANE="$B" claude_mark_activity tool-start AskUserQuestion
TMUX_PANE="$B" HOOKS="$HOOKS" bash -c 'source "$HOOKS/lib/state.sh"
  printf "phase=%s tool=%s beat=%s\n" "$(claude_pane_opt @claude-pane-phase)" \
    "$(claude_pane_opt @claude-pane-tool)" "$(claude_pane_opt @claude-pane-beat)"'

t kill-session -t hooktest 2>/dev/null
