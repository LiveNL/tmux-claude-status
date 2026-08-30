#!/bin/bash
# A question owns the tab until it is answered.
#
# The pane's state slot is shared: subagents and background commands fire their
# own PreToolUse/PostToolUse against it, and each one used to repaint the amber
# question tab teal while the question was still on screen.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT

export TMUX

t new-session -d -s asktest -x 80 -y 24
WIN=$(t list-windows -t asktest -F '#{window_id}' | head -1)
P=$(t list-panes -t "$WIN" -F '#{pane_id}' | head -1)
LOCK="/tmp/claude-spinner-${P#%}.lock"
PLOCK="/tmp/claude-permission-${P#%}.lock"
rm -rf "$LOCK" "$PLOCK"

busy() { printf '{"hook_event_name":"%s","tool_name":"%s"}' "$1" "$2" | TMUX_PANE="$P" bash "$HOOKS/busy-window.sh"; }
state() { TMUX_PANE=$P claude_pane_state; }

busy PreToolUse AskUserQuestion
check "question latches" "$(TMUX_PANE=$P claude_pane_opt @claude-pane-ask)" "AskUserQuestion"

# The case this whole latch exists for: a subagent's tool boundary lands on the
# same pane while the question is still unanswered.
busy PostToolUse Bash
check "a subagent's tool does not steal the tab" "$(state)" "input"
check "window follows the pane" "$(t show-options -wqv -t "$WIN" @claude-state)" "input"
[ -d "$LOCK" ] && echo "FAIL a subagent started a spinner under a question" \
    || echo "ok   no spinner while a question stands"

busy PreToolUse Read
check "and neither does its next call" "$(state)" "input"

# Answering retires it.
busy PostToolUse AskUserQuestion
check "answering clears the latch" "$(TMUX_PANE=$P claude_pane_opt @claude-pane-ask)" ""
check "answering resumes the run" "$(state)" "running"
rm -rf "$LOCK"

# Escaping a question leaves no PostToolUse behind, so the next prompt retires it.
busy PreToolUse ExitPlanMode
check "a plan latches too" "$(state)" "input"
busy UserPromptSubmit ""
check "a new prompt clears the latch" "$(TMUX_PANE=$P claude_pane_opt @claude-pane-ask)" ""
check "and the tab runs again" "$(state)" "running"
rm -rf "$LOCK"

# So does the turn ending.
busy PreToolUse AskUserQuestion
printf '{"hook_event_name":"Stop","last_assistant_message":"Done."}' | TMUX_PANE="$P" bash "$HOOKS/notify.sh"
check "stop clears the latch" "$(TMUX_PANE=$P claude_pane_opt @claude-pane-ask)" ""
check "stop has its say" "$(state)" "done"

# A permission dialog is the more urgent of the two and still wins — but once
# it is answered the tab must fall back to the question, not to running.
busy PreToolUse AskUserQuestion
printf '{"hook_event_name":"PermissionRequest"}' | TMUX_PANE="$P" bash "$HOOKS/permission-window.sh"
check "permission outranks a question" "$(state)" "permission"
TMUX_PANE=$P claude_mark_activity "tool-end" "Bash"
sleep 1.2
check "released permission falls back to the question" "$(state)" "input"

rm -rf "$LOCK" "$PLOCK"
