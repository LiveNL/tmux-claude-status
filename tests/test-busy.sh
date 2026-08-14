#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT
# Spinner lifecycle test for busy-window.sh in a throwaway t session.

export TMUX

t kill-session -t busytest 2>/dev/null
t new-session -d -s busytest -x 80 -y 24
WIN=$(t list-windows -t busytest -F '#{window_id}' | head -1)
P=$(t list-panes -t "$WIN" -F '#{pane_id}' | head -1)
LOCK="/tmp/claude-spinner-${P#%}.lock"
rm -rf "$LOCK"

check() { if [ "$2" = "$3" ]; then echo "ok   $1 -> '$2'"; else echo "FAIL $1 -> '$2' (want '$3')"; fi; }

printf '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' | TMUX_PANE="$P" bash "$HOOKS/busy-window.sh"
check "pane state" "$(TMUX_PANE=$P claude_pane_state)" "running"
check "window state" "$(t show-options -wqv -t "$WIN" @claude-state)" "running"
check "phase" "$(TMUX_PANE=$P claude_pane_opt @claude-pane-phase)" "tool-start"
check "tool" "$(TMUX_PANE=$P claude_pane_opt @claude-pane-tool)" "Bash"
[ -d "$LOCK" ] && echo "ok   spinner lock created" || echo "FAIL spinner lock missing"

f1=$(t show-options -wqv -t "$WIN" @claude-spinner)
sleep 0.7
f2=$(t show-options -wqv -t "$WIN" @claude-spinner)
[ "$f1" != "$f2" ] && echo "ok   spinner animates ($f1 -> $f2)" || echo "FAIL spinner frozen on $f1"

# A second concurrent call must not spawn a second spinner.
printf '{"hook_event_name":"PreToolUse","tool_name":"Read"}' | TMUX_PANE="$P" bash "$HOOKS/busy-window.sh"
spinners=$(pgrep -fc "claude-spinner-${P#%}" 2>/dev/null || echo 0)
echo "info spinner procs matching lock name: $spinners (lock dir is the guard)"

# Stop ends the run: the loop must notice and clean up its lock.
printf '{"hook_event_name":"Stop","last_assistant_message":"Done."}' | TMUX_PANE="$P" bash "$HOOKS/notify.sh"
sleep 1.2
check "state after stop" "$(TMUX_PANE=$P claude_pane_state)" "done"
[ -d "$LOCK" ] && echo "FAIL lock still present after stop" || echo "ok   spinner exited and removed lock"

t kill-session -t busytest 2>/dev/null
rm -rf "$LOCK"
