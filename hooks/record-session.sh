#!/bin/bash
# Fired on SessionStart. Stamps the Claude session id onto the tmux pane.
#
# tmux knows a pane's directory and its running command, and both are captured
# by ~/.config/tmux/scripts/tmux-snapshot.sh — but the conversation inside that
# pane is invisible to it. The transcript survives any crash under
# ~/.claude/projects/<slug>/<session_id>.jsonl; the id is the only thing that
# ties it back to the window it lived in, and it exists nowhere else.
#
# SessionStart is a blocking hook: Claude pipes JSON to stdin and waits, so the
# payload is drained first, before anything can fail.

payload=$(cat 2>/dev/null)

[ -n "$TMUX" ] || exit 0

sid=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)

# jq is the normal path, but a hook that silently stops recording is worse than
# a crude parser: a session id is a uuid, so it can never contain a quote.
if [ -z "$sid" ]; then
    sid=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$payload" | head -1)
fi

[ -n "$sid" ] || exit 0

# Pane-scoped, not window-scoped: a split can hold a second conversation, and
# the snapshot records one row per pane.
tmux set-option -p -t "$TMUX_PANE" @claude-session "$sid" 2>/dev/null

# Cheap and unconditional — the snapshot is written on a timer, and a session
# that starts and dies inside one interval would otherwise never be recorded.
SNAP="$HOME/.config/tmux/scripts/tmux-snapshot.sh"
[ -x "$SNAP" ] && "$SNAP" snap >/dev/null 2>&1 &

exit 0
