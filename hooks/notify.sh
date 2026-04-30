#!/bin/bash
# Fired on Stop and Notification events.
# Updates the tmux window state and sends a desktop notification (macOS only).

NOTIFIER_INPUT=$(cat)
MESSAGE=$(echo "$NOTIFIER_INPUT" | jq -r '.message // empty')
EVENT=$(echo "$NOTIFIER_INPUT" | jq -r '.hook_event_name // empty')
LAST_MSG=$(echo "$NOTIFIER_INPUT" | jq -r '.last_assistant_message // empty')

TMUX_WINDOW=""
TMUX_SESSION=""
TMUX_WINDOW_INDEX=""
IS_ACTIVE="0"
if [ -n "$TMUX" ]; then
    TMUX_WINDOW=$(tmux display-message -t "$TMUX_PANE" -p '#W')
    TMUX_SESSION=$(tmux display-message -t "$TMUX_PANE" -p '#S')
    TMUX_WINDOW_INDEX=$(tmux display-message -t "$TMUX_PANE" -p '#I')
    IS_ACTIVE=$(tmux display-message -t "$TMUX_PANE" -p '#{window_active}')
fi

REPO_NAME=$(basename "$(pwd)")

# Strip markdown and return first sentence, falling back to 80 chars
preview() {
    local cleaned
    cleaned=$(echo "$1" \
        | tr '\n' ' ' \
        | sed 's/\*\*//g; s/\*//g; s/__//g; s/`[^`]*`//g; s/`//g' \
        | sed 's/|[^|]*|//g; s/|//g' \
        | sed 's/^ *[-–•] //g; s/ [-–•] / /g' \
        | sed 's/#\+[[:space:]]//g' \
        | sed 's/--[a-zA-Z][a-zA-Z-]*//g' \
        | sed 's/  */ /g; s/^ *//; s/ *$//')
    local sentence
    sentence=$(printf '%s' "$cleaned" | grep -oE '^.{10,100}[.!?]' | head -1)
    printf '%s' "${sentence:-$(printf '%s' "$cleaned" | cut -c1-80)}"
}

# macOS notifications (no-op on other platforms)
CAN_NOTIFY="0"
if [ "$(uname)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    CAN_NOTIFY="1"
fi

set_state() {
    if [ -n "$TMUX" ]; then
        tmux set-option -w -t "$TMUX_PANE" @claude-state "$1"
        tmux refresh-client -S
    fi
}

# Args: event_label msg sound
# Title = repo name (prominent), subtitle = event label
notify_macos() {
    [ "$CAN_NOTIFY" = "1" ] || return 0
    local event="$1" msg="$2" sound="$3"
    local title="$REPO_NAME"
    local subtitle="$event"

    # alerter blocks until user interacts, so run in background subshell.
    # On click (not timeout/dismiss), switch to the tmux window and focus the terminal.
    if command -v alerter >/dev/null 2>&1 && [ -n "$TMUX_SESSION" ]; then
        local sender=""
        for bundle in "org.alacritty" "com.googlecode.iterm2" "com.apple.Terminal" "co.ghostty.ghostty" "net.kovidgoyal.kitty" "dev.warp.Warp-Preview"; do
            if osascript -e "application id \"$bundle\" is running" 2>/dev/null | grep -q "true"; then
                sender="$bundle"
                break
            fi
        done

        local tmux_target="${TMUX_SESSION}:${TMUX_WINDOW_INDEX}"
        (
            result=$(alerter \
                --title "$title" \
                --subtitle "$subtitle" \
                --message "$msg" \
                --sound "$sound" \
                --timeout 30 \
                ${sender:+--sender "$sender"} 2>/dev/null)
            case "$result" in
                @TIMEOUT|@CLOSED) ;;
                *)
                    tmux switch-client -t "$tmux_target" 2>/dev/null
                    [ -n "$sender" ] && osascript -e "tell application id \"$sender\" to activate" 2>/dev/null
                    ;;
            esac
        ) &
        disown
        return
    fi

    osascript -e "display notification \"$msg\" with title \"$title\" subtitle \"$subtitle\" sound name \"$sound\""
}

if [ -n "$TMUX" ] && [ "${DEBUG_CLAUDE_HOOKS:-0}" = "1" ]; then
    echo "$(date '+%H:%M:%S') event=$EVENT state=$(tmux display-message -t "$TMUX_PANE" -p '#{@claude-state}' 2>/dev/null) msg=${MESSAGE:-$LAST_MSG}" >> /tmp/claude-notify.log
fi

if [ -z "$EVENT" ]; then
    # Could not parse hook input — reset to idle to avoid stuck state
    set_state ""
    exit 0
fi

if [ "$EVENT" = "Stop" ]; then
    PREVIEW=$(preview "$LAST_MSG")
    if echo "$LAST_MSG" | grep -q '?$'; then
        set_state "input"
        if [ "$IS_ACTIVE" != "1" ]; then
            notify_macos "❓ Question" "${PREVIEW:-Claude needs your input}" "Pop"
        fi
    else
        set_state "done"
        if [ "$IS_ACTIVE" != "1" ]; then
            notify_macos "✅ Done" "${PREVIEW:-Ready for review}" "Glass"
        fi
    fi
elif [ "$EVENT" = "Notification" ]; then
    if echo "$MESSAGE" | grep -qi "permission"; then
        CMD=$(echo "$MESSAGE" | sed 's/.*[Rr]un[: ]\{1,3\}//' | sed 's/  */ /g; s/^ *//; s/ *$//' | cut -c1-60)
        if [ -n "$CMD" ] && [ "$CMD" != "$MESSAGE" ]; then
            notify_macos "🔑 Permission" "Run: $CMD" "Sosumi"
        else
            notify_macos "🔑 Permission" "${MESSAGE:-Needs your approval}" "Sosumi"
        fi
    else
        CURRENT_STATE=$(tmux display-message -t "$TMUX_PANE" -p '#{@claude-state}' 2>/dev/null)
        if [ "$CURRENT_STATE" != "done" ] && [ "$CURRENT_STATE" != "input" ]; then
            set_state "input"
        fi
        if [ "$IS_ACTIVE" != "1" ]; then
            notify_macos "💬 Input needed" "${MESSAGE:-Claude needs your attention}" "Pop"
        fi
    fi
fi
