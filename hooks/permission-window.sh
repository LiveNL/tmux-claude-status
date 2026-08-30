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

# Nothing reports the answer, so a watcher has to catch it. It lives in the
# shared lib because notify.sh paints the same red on its own permission
# Notification — and red painted without a watcher never comes back.
claude_arm_permission_watcher "$TMUX_PANE"

exit 0
