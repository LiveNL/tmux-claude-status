#!/bin/bash
# Stop fires before the stop-hook chain runs, and a hook can hand the turn
# back. The tab went green while "running stop hook" was still on screen and
# tokens were still arriving; nothing fired again until the next tool call, so
# a continuation that only writes prose kept a lying tab for its whole length.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT

export TMUX

t new-session -d -s conttest -x 80 -y 24
WIN=$(t list-windows -t conttest -F '#{window_id}' | head -1)
P=$(t list-panes -t "$WIN" -F '#{pane_id}' | head -1)
LOCK="/tmp/claude-continue-${P#%}.lock"
SLOCK="/tmp/claude-spinner-${P#%}.lock"
rm -rf "$LOCK" "$SLOCK"

TRANSCRIPT=$(mktemp)
trap 'rm -f "$TRANSCRIPT"; rm -rf "$LOCK" "$SLOCK"; test_server_stop' EXIT

main() { printf '{"isSidechain":false,"type":"assistant","x":1}\n' >> "$TRANSCRIPT"; }
side() { printf '{"isSidechain":true,"type":"assistant","x":1}\n' >> "$TRANSCRIPT"; }

stop() { # last assistant message
    printf '{"hook_event_name":"Stop","last_assistant_message":"%s","transcript_path":"%s"}' "$1" "$TRANSCRIPT" \
        | TMUX_PANE="$P" bash "$HOOKS/notify.sh"
}
state() { TMUX_PANE=$P claude_pane_state; }

main
stop "Done."
check "stop paints done" "$(state)" "done"
[ -d "$LOCK" ] && echo "ok   a watcher is armed" || echo "FAIL nothing watching the transcript"

# The 3 background agents keep writing to the same file. They are not the chat.
side; side
sleep 1.2
check "subagents do not un-finish the turn" "$(state)" "done"
[ -d "$SLOCK" ] && echo "FAIL a sidechain started a spinner" || echo "ok   no spinner for sidechain writes"

# The stop hook hands the turn back: the main thread writes again.
main
sleep 1.2
check "a continuation turns the tab back" "$(state)" "running"
check "and says why" "$(TMUX_PANE=$P claude_pane_opt @claude-pane-phase)" "continuation"
[ -d "$LOCK" ] && echo "FAIL watcher lingered after releasing" || echo "ok   watcher exited once it fired"
rm -rf "$SLOCK"

# The next Stop has the final say, and arms a fresh watcher.
main
stop "All set."
check "the second stop paints done" "$(state)" "done"

# A turn that ends for real stays ended.
sleep 1.2
check "silence leaves the tab alone" "$(state)" "done"

# A tab someone else has already claimed is not repainted from here.
main
TMUX_PANE=$P claude_set_state "permission"
sleep 1.2
check "a permission dialog outranks the watcher" "$(state)" "permission"
