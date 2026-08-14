#!/bin/bash
# Fired on PermissionRequest.
# Sets the pane state to "permission" immediately so the tab turns red
# before the Notification event arrives.
# The spinner loop keeps running so the elapsed timer stays current.

# Drain stdin first: Claude pipes the payload in and holds the write end open
# until it is consumed.
payload=$(cat 2>/dev/null)

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

claude_bootstrap "$payload" || exit 0

claude_mark_activity "permission" ""
claude_set_state "permission"

# Nothing reports the answer. Claude fires no event when you approve, and the
# next one — PostToolUse — only arrives when the command finishes, so a granted
# permission left the tab red for the entire run. Watch for the command instead:
# Claude spawns it only after approval, so a shell under the session process is
# the answer arriving. One watcher per pane, and it gives up rather than linger.
LOCK="/tmp/claude-permission-${TMUX_PANE#%}.lock"
mkdir "$LOCK" 2>/dev/null || exit 0

pane="$TMUX_PANE"
(
    trap 'rm -rf "$LOCK" 2>/dev/null' EXIT
    trap 'exit 0' INT TERM HUP
    pane_pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
    for _ in $(seq 1 1200); do
        sleep 0.5
        state=$(tmux show-options -pqv -t "$pane" @claude-pane-state 2>/dev/null)
        [ "$state" = "permission" ] || exit 0
        if claude_pane_executing "$pane_pid"; then
            TMUX_PANE="$pane" claude_set_state "running"
            TMUX_PANE="$pane" claude_mark_activity "tool-start" ""
            claude_start_spinner "$pane"
            exit 0
        fi
    done
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
exit 0
