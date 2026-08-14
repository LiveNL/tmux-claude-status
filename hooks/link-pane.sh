#!/bin/bash
# Bind the pane you run this in to a conversation, by hand.
#
# Needed for a session that was never started inside a pane: Claude hosts it in
# its daemon, the pane holds only a client, and no process argument, file or
# environment ties the two together. The stamp this writes is the missing fact,
# and hooks from that conversation — and from anything it forks — then find
# this tab like any other.
#
#   link-pane.sh <session-id>   bind this pane to that conversation
#   link-pane.sh --guess        show the conversations of this pane's project
#   link-pane.sh --clear        drop the binding

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/session-map.sh"

[ -n "$TMUX_PANE" ] || { echo "run this inside the tmux pane you want to bind" >&2; exit 1; }

case "$1" in
    --clear)
        tmux set-option -p -u -t "$TMUX_PANE" @claude-session
        echo "unbound $TMUX_PANE"
        ;;
    --guess|"")
        cwd=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_current_path}')
        dir=$(claude_project_dir "$cwd")
        echo "conversations under $cwd, most recent first:"
        ls -t "$dir"/*.jsonl 2>/dev/null | head -8 | while IFS= read -r f; do
            printf '  %s  %s\n' "$(date -r "$f" '+%m-%d %H:%M')" "$(basename "$f" .jsonl)"
        done
        echo
        echo "bind with: $(basename "$0") <session-id>"
        ;;
    *)
        claude_stamp_session "$TMUX_PANE" "$1"
        echo "bound $TMUX_PANE to $1 (now: $(tmux show-options -pqv -t "$TMUX_PANE" @claude-session))"
        ;;
esac
