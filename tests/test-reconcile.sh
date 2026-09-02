#!/bin/bash
# The reconciler corrects a tab that drifted from Claude's own session file,
# and keeps its hands off fresh edges, questions, and dead sessions.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT

RECON="$HOOKS/reconcile-panes.sh"
SESSIONS=$(mktemp -d); trap 'rm -rf "$SESSIONS"; test_server_stop' EXIT

t kill-session -t recontest 2>/dev/null
t new-session -d -s recontest -x 80 -y 24 -c /tmp
W=$(t list-windows -t recontest -F '#{window_id}' | head -1)
P=$(t list-panes -t "$W" -F '#{pane_id}' | head -1)

# One session file the reconciler will read; pid is this test, so it is alive.
OLD_MS=$(( ($(date +%s) - 30) * 1000 ))
sess() { # status [statusUpdatedAt_ms] [pid]
    printf '{"pid":%s,"sessionId":"t-1","status":"%s","statusUpdatedAt":%s,"tmux":"recontest:%s.%s"}\n' \
        "${3:-$$}" "$1" "${2:-$OLD_MS}" "$W" "$P" > "$SESSIONS/$$.json"
}
run() { CLAUDE_SESSIONS_DIR="$SESSIONS" bash "$RECON"; }
stale_beat() { t set-option -p -t "$P" @claude-pane-beat "$(( $(date +%s) - 60 ))"; }

# 1. busy corrects a settled tab
TMUX_PANE=$P claude_set_settled done
TMUX_PANE=$P claude_set_state done
stale_beat
sess busy
run
check "busy overrides a settled done" "$(claude_pane_state "$P")" "running"
check "and releases the settled hold" "$(TMUX_PANE=$P claude_pane_opt @claude-pane-settled)" ""

# 2. an open question outranks busy
TMUX_PANE=$P claude_set_ask AskUserQuestion
TMUX_PANE=$P claude_set_state input
stale_beat
sess busy
run
check "a pending question outranks busy" "$(claude_pane_state "$P")" "input"
TMUX_PANE=$P claude_clear_ask

# 3. waiting paints permission
TMUX_PANE=$P claude_set_state running
stale_beat
sess waiting
run
check "waiting paints permission" "$(claude_pane_state "$P")" "permission"

# 4. idle retires a spinning tab to input
TMUX_PANE=$P claude_set_state running
stale_beat
sess idle
run
check "idle retires running to input" "$(claude_pane_state "$P")" "input"

# 5. a fresh hook edge is left alone
TMUX_PANE=$P claude_clear_settled
TMUX_PANE=$P claude_mark_activity tool-end ""   # beat = now
TMUX_PANE=$P claude_set_state done
sess busy
run
check "a fresh hook edge wins" "$(claude_pane_state "$P")" "done"

# 6. a status that just flipped is left alone
stale_beat
NOW_MS=$(( $(date +%s) * 1000 ))
sess busy "$NOW_MS"
run
check "a fresh file edge waits its turn" "$(claude_pane_state "$P")" "done"

# 7. a file whose process is gone is a leftover
stale_beat
sess busy "$OLD_MS" 99999999
run
check "a dead session's file is ignored" "$(claude_pane_state "$P")" "done"

# 8. agreement is a no-op
TMUX_PANE=$P claude_set_state running
stale_beat
sess busy
run
check "busy under a running tab changes nothing" "$(claude_pane_state "$P")" "running"
