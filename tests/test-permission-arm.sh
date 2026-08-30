#!/bin/bash
# The watcher that turns a red tab back, and the two ways it is armed.
#
# notify.sh paints the same red as PermissionRequest, one event later. It used
# to paint it without arming anything, and since the lock is one per pane the
# first watcher had already spent it — so that red was the last word and the
# tab stayed red for the rest of the run.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT

export TMUX

t new-session -d -s permtest -x 80 -y 24
WIN=$(t list-windows -t permtest -F '#{window_id}' | head -1)
P=$(t list-panes -t "$WIN" -F '#{pane_id}' | head -1)
LOCK="/tmp/claude-permission-${P#%}.lock"
SLOCK="/tmp/claude-spinner-${P#%}.lock"
rm -rf "$LOCK" "$SLOCK"

state() { TMUX_PANE=$P claude_pane_state; }
arm_red() { # simulates PermissionRequest
    TMUX_PANE=$P claude_mark_activity "permission" ""
    TMUX_PANE=$P claude_set_state "permission"
    TMUX_PANE=$P claude_arm_permission_watcher "$P"
}

# A dead watcher must not lock the pane red forever.
mkdir -p "$LOCK"; echo 999999 > "$LOCK/pid"
arm_red
pid=$(cat "$LOCK/pid" 2>/dev/null)
[ "$pid" != "999999" ] && [ -n "$pid" ] && echo "ok   a stale lock is reclaimed (pid $pid)" \
    || echo "FAIL stale lock blocked the watcher"

# A live one must not be doubled.
live=$(cat "$LOCK/pid")
TMUX_PANE=$P claude_arm_permission_watcher "$P"
check "a live watcher is not replaced" "$(cat "$LOCK/pid")" "$live"

# A subagent's grant never shows up under the pane's own process — its command
# runs under the daemon. The activity beat moving is the only evidence, so it
# has to be enough.
TMUX_PANE=$P claude_mark_activity "tool-end" "Bash"
sleep 1.2
check "a moving beat releases the red" "$(state)" "running"
rm -rf "$LOCK" "$SLOCK"

# But a second dialog stamps a beat of its own, and that must not read as the
# first one being answered.
arm_red
sleep 0.4
TMUX_PANE=$P claude_mark_activity "permission" ""
sleep 1.2
check "a queued second dialog keeps the tab red" "$(state)" "permission"

# notify.sh's own permission Notification arms a watcher too, even though the
# earlier one has already exited with the lock.
TMUX_PANE=$P claude_set_state "running"
sleep 0.8
rm -rf "$LOCK"
printf '{"hook_event_name":"Notification","message":"Claude needs your permission to run"}' \
    | TMUX_PANE="$P" bash "$HOOKS/notify.sh"
check "the notification paints red" "$(state)" "permission"
[ -d "$LOCK" ] && echo "ok   the notification armed a watcher" || echo "FAIL red painted with no way back"

TMUX_PANE=$P claude_mark_activity "tool-end" "Bash"
sleep 1.2
check "and that watcher releases it" "$(state)" "running"

rm -rf "$LOCK" "$SLOCK"
