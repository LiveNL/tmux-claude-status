#!/bin/bash
# Fired on Stop and Notification events.
# Updates the tmux window state and sends a desktop notification (macOS only).

NOTIFIER_INPUT=$(cat)
_sid=$(printf %s "$NOTIFIER_INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

# Env probe: a session was seen running this hook while none of its tmux
# writes landed. Logs only while the file exists — delete it to switch off.
[ -f /tmp/claude-hook-env.log ] && {
    _anc=""; _p=$PPID
    for _ in 1 2 3 4; do
        _line=$(ps -p "$_p" -o ppid=,comm= 2>/dev/null) || break
        _anc="$_anc <- $(printf '%s' "$_line" | awk '{print $2}' | xargs basename 2>/dev/null)"
        _p=$(printf '%s' "$_line" | awk '{print $1}')
        [ -z "$_p" ] || [ "$_p" = "1" ] && break
    done
    printf '%s %s pane=%s tmux=%s sid=%s cwd=%s anc=%s\n' "$(date +%H:%M:%S)" "notify" "${TMUX_PANE:-UNSET}" "${TMUX:+set}" "$_sid" "$PWD" "$_anc" >> /tmp/claude-hook-env.log
}

MESSAGE=$(echo "$NOTIFIER_INPUT" | jq -r '.message // empty')
EVENT=$(echo "$NOTIFIER_INPUT" | jq -r '.hook_event_name // empty')
LAST_MSG=$(echo "$NOTIFIER_INPUT" | jq -r '.last_assistant_message // empty')

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

claude_bootstrap "$NOTIFIER_INPUT" || exit 0

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

# alerter carries the terminal's own icon; the osascript fallback is stuck with
# Script Editor's. A GUI-launched Claude inherits a PATH without Homebrew, so
# look the binary up by absolute path too rather than losing the icon.
ALERTER=$(command -v alerter 2>/dev/null)
for candidate in /opt/homebrew/bin/alerter /usr/local/bin/alerter; do
    [ -n "$ALERTER" ] && break
    [ -x "$candidate" ] && ALERTER="$candidate"
done

set_state() {
    claude_set_state "$1"
}

# Claude sends the same "needs your attention" Notification whether it is
# blocked on you or merely slow, so the message alone cannot be trusted to
# retire a run: taking it at face value flipped a busy tab to amber mid-run
# and killed its spinner. Decide from what the pane was last seen doing.
awaiting_user() {
    local phase tool beat age
    # Not running: Stop already had its say, so the event is about an idle
    # session and can be believed.
    [ "$(claude_pane_state)" = "running" ] || return 0

    phase=$(claude_pane_opt @claude-pane-phase)
    tool=$(claude_pane_opt @claude-pane-tool)
    # A question tool is in flight — Claude really is parked on an answer.
    case "$phase:$tool" in
        tool-start:AskUserQuestion|tool-start:ExitPlanMode) return 0 ;;
    esac

    # Otherwise only stalled work counts. A live run stamps a beat on every
    # tool boundary; five quiet minutes means the run is no longer moving.
    beat=$(claude_pane_opt @claude-pane-beat)
    age=$(( $(date +%s) - ${beat:-0} ))
    [ "$age" -ge 300 ]
}

# Args: event_label msg sound
# Title = repo name (prominent), subtitle = event label
# Sounds muted 2026-08-24: banners only. The empty sound skips the flag/clause
# below; re-enable by restoring sound="$3" — call sites still pass the names.
notify_macos() {
    [ "$CAN_NOTIFY" = "1" ] || return 0
    local event="$1" msg="$2" sound=""
    local title="$REPO_NAME"
    local subtitle="$event"

    # alerter blocks until user interacts, so run in background subshell.
    # On click (not timeout/dismiss), switch to the tmux window and focus the
    # terminal. Sessions outside tmux still take this path — they just skip the
    # window switch — so the notification keeps the terminal's icon.
    if [ -n "$ALERTER" ]; then
        local sender=""
        for bundle in "org.alacritty" "com.googlecode.iterm2" "com.apple.Terminal" "co.ghostty.ghostty" "net.kovidgoyal.kitty" "dev.warp.Warp-Preview"; do
            if osascript -e "application id \"$bundle\" is running" 2>/dev/null | grep -q "true"; then
                sender="$bundle"
                break
            fi
        done

        local tmux_target=""
        [ -n "$TMUX_SESSION" ] && tmux_target="${TMUX_SESSION}:${TMUX_WINDOW_INDEX}"
        (
            result=$("$ALERTER" \
                --title "$title" \
                --subtitle "$subtitle" \
                --message "$msg" \
                ${sound:+--sound "$sound"} \
                --timeout 30 \
                ${sender:+--sender "$sender"} 2>/dev/null)
            case "$result" in
                @TIMEOUT|@CLOSED) ;;
                *)
                    [ -n "$tmux_target" ] && tmux switch-client -t "$tmux_target" 2>/dev/null
                    [ -n "$sender" ] && osascript -e "tell application id \"$sender\" to activate" 2>/dev/null
                    ;;
            esac
        ) &
        disown
        return
    fi

    osascript -e "display notification \"$msg\" with title \"$title\" subtitle \"$subtitle\"${sound:+ sound name \"$sound\"}"
}

if [ -n "$TMUX" ] && [ "${DEBUG_CLAUDE_HOOKS:-0}" = "1" ]; then
    DBG_BEAT=$(claude_pane_opt @claude-pane-beat)
    printf '%s event=%s pane=%s state=%s window=%s phase=%s tool=%s beat=%ss msg=%s\n' \
        "$(date '+%H:%M:%S')" "$EVENT" "$TMUX_PANE" \
        "$(claude_pane_state)" \
        "$(tmux display-message -t "$TMUX_PANE" -p '#{@claude-state}' 2>/dev/null)" \
        "$(claude_pane_opt @claude-pane-phase)" \
        "$(claude_pane_opt @claude-pane-tool)" \
        "$(( $(date +%s) - ${DBG_BEAT:-0} ))" \
        "${MESSAGE:-$LAST_MSG}" >> /tmp/claude-notify.log 2>/dev/null
fi

if [ -z "$EVENT" ]; then
    # Could not parse hook input — reset to idle to avoid stuck state
    set_state ""
    exit 0
fi

if [ "$EVENT" = "Stop" ]; then
    claude_mark_activity "stop" ""
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
        # PermissionRequest normally paints the tab first, but that event is
        # newer than this one — set it here too so older clients still turn red.
        set_state "permission"
        CMD=$(echo "$MESSAGE" | sed 's/.*[Rr]un[: ]\{1,3\}//' | sed 's/  */ /g; s/^ *//; s/ *$//' | cut -c1-60)
        if [ -n "$CMD" ] && [ "$CMD" != "$MESSAGE" ]; then
            notify_macos "🔑 Permission" "Run: $CMD" "Sosumi"
        else
            notify_macos "🔑 Permission" "${MESSAGE:-Needs your approval}" "Sosumi"
        fi
    elif awaiting_user; then
        # Both "done" and "input" mean your turn, and "done" is the more
        # precise of the two — it says the turn ended without a question. The
        # idle notification that arrives a minute later must not overwrite it,
        # or every finished tab quietly turns back into a question mark.
        case "$(claude_pane_state)" in
            permission|done) ;;
            *) set_state "input" ;;
        esac
        if [ "$IS_ACTIVE" != "1" ]; then
            notify_macos "💬 Input needed" "${MESSAGE:-Claude needs your attention}" "Pop"
        fi
    fi
fi
