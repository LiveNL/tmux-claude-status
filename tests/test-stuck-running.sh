#!/bin/bash
# A pane stuck on "running" with its own spinner alive must still be retired
# once the screen shows an idle prompt. The spinner is not evidence: it runs
# because the state says running, so trusting it made the state permanent.
HOOKS=/Users/livenl/projects/claude-tmux-hooks/hooks
source "$HOOKS/lib/state.sh"
: "${TMUX:=$(tmux display-message -p '#{socket_path},0,0')}"; export TMUX

tmux kill-session -t stucktest 2>/dev/null
tmux new-session -d -s stucktest -x 80 -y 24
W=$(tmux list-windows -t stucktest -F '#{window_id}' | head -1)
P=$(tmux list-panes -t "$W" -F '#{pane_id}' | head -1)

# Paint an idle Claude footer onto the pane so the reader sees a real session.
tmux send-keys -t "$P" "clear; printf '\\n  ❯ \\n  -- INSERT -- auto mode on (shift+tab to cycle)\\n  ? for shortcuts\\n'" Enter
sleep 1

TMUX_PANE="$P" claude_set_state running
claude_start_spinner "$P"
lock="/tmp/claude-spinner-${P#%}.lock"
[ -d "$lock" ] && echo "ok   spinner started" || echo "FAIL no spinner"

bash "$HOOKS/reconcile-panes.sh" >/dev/null 2>&1
got=$(TMUX_PANE="$P" claude_pane_state)
[ "$got" = "input" ] && echo "ok   stuck running retired -> '$got'" || echo "FAIL stuck -> '$got' (want input)"

sleep 1
[ -d "$lock" ] && echo "FAIL spinner outlived the state" || echo "ok   spinner exited with the state"

tmux kill-session -t stucktest 2>/dev/null
rm -rf "$lock"
