#!/bin/bash
# Granting a permission produces no event of its own. Claude only spawns the
# command once you have answered, so a shell under the session process is the
# answer arriving — that is what releases the red tab.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT

TABLE=$(mktemp); trap 'rm -f "$TABLE"' EXIT

# 100 pane shell -> 101 claude ; waiting on the dialog, nothing running yet
printf '100 1 -zsh\n101 100 /Users/livenl/.local/bin/claude\n102 101 caffeinate\n' > "$TABLE"
claude_pane_executing 100 "$TABLE" && echo "FAIL dialog still open reads as running" \
    || echo "ok   waiting on the dialog is not running"

# answered: claude spawns a shell for the command
printf '100 1 -zsh\n101 100 /Users/livenl/.local/bin/claude\n102 101 caffeinate\n103 101 /bin/zsh\n104 103 sleep\n' > "$TABLE"
claude_pane_executing 100 "$TABLE" && echo "ok   a command under the session reads as running" \
    || echo "FAIL answered dialog not detected"

# a language server is not a command
printf '100 1 -zsh\n101 100 /Users/livenl/.local/bin/claude\n105 101 node\n' > "$TABLE"
claude_pane_executing 100 "$TABLE" && echo "FAIL language server counted as a command" \
    || echo "ok   language servers do not count"

# the pane's own login shell is not evidence either
printf '100 1 -zsh\n' > "$TABLE"
claude_pane_executing 100 "$TABLE" && echo "FAIL bare shell counted" \
    || echo "ok   a pane without a session is not running"
