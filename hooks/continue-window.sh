#!/bin/bash
# Fired on PostToolUse.
# Restores the running state without resetting the spinner or elapsed timer.
# Handles the permission → running transition after a grant.

# Drain stdin first: Claude pipes the payload in and holds the write end open
# until it is consumed.
payload=$(cat 2>/dev/null)

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

claude_bootstrap "$payload" || exit 0

# Stamp the tool boundary as well — notify.sh reads it to tell a run that is
# still moving from one that has genuinely stalled waiting on you.
claude_mark_activity "tool-end" ""
claude_set_state "running"
