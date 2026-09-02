#!/bin/bash
# Pin the shape of ~/.claude/sessions/<pid>.json — the internal Claude Code
# file the reconciler reads. Four fields matter: pid, status, statusUpdatedAt,
# tmux. A Claude release that renames or retypes them must fail here, not
# silently stop correcting tabs.
#
# Runs against the live files on this machine; on a machine with no running
# session (CI), it says so and passes.
DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"

live=0
for f in "$DIR"/*.json; do
    [ -f "$f" ] || continue
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || continue
    live=$(( live + 1 ))

    status=$(jq -r '.status // empty' "$f")
    case "$status" in
        busy|waiting|idle) echo "ok   $(basename "$f"): status '$status' is a known value" ;;
        *) echo "FAIL $(basename "$f"): status '$status' not in busy|waiting|idle" ;;
    esac

    updated=$(jq -r '.statusUpdatedAt // empty' "$f")
    case "$updated" in
        *[!0-9]*|'') echo "FAIL $(basename "$f"): statusUpdatedAt '$updated' is not epoch-ms" ;;
        *) echo "ok   $(basename "$f"): statusUpdatedAt is epoch-ms" ;;
    esac

    tmuxref=$(jq -r '.tmux // empty' "$f")
    if [ -z "$tmuxref" ]; then
        echo "ok   $(basename "$f"): no tmux binding (session outside tmux)"
    elif printf '%s' "$tmuxref" | grep -qE '^[^:]+:@[0-9]+\.%[0-9]+$'; then
        echo "ok   $(basename "$f"): tmux binding '$tmuxref' parses"
    else
        echo "FAIL $(basename "$f"): tmux binding '$tmuxref' does not match session:@window.%pane"
    fi
done

if [ "$live" -eq 0 ]; then
    echo "ok   no live session files to check (nothing running here)"
fi
