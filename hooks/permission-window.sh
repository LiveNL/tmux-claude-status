#!/bin/bash
# Fired on PermissionRequest.
# Sets the pane state to "permission" immediately so the tab turns red
# before the Notification event arrives.
# The spinner loop keeps running so the elapsed timer stays current.

# Drain stdin first: Claude pipes the payload in and holds the write end open
# until it is consumed.
cat >/dev/null 2>&1

[ -n "$TMUX" ] || exit 0

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

claude_mark_activity "permission" ""
claude_set_state "permission"
