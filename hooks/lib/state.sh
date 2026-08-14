#!/bin/bash
# Shared state helpers. Sourced by every hook that touches the tab indicator.
#
# State lives on the *pane* (@claude-pane-state); the window option the status
# bar reads (@claude-state) is recomputed as the highest-priority state of any
# pane in that window. Two Claude sessions can then share one tmux window
# without overwriting each other — one finishing no longer clears the tab of
# the one still running — and because a pane option dies with its pane, a
# closed session can never strand a stale indicator on the tab.
#
# Priority: permission > running > input > done > idle.

claude_state_rank() {
    case "$1" in
        permission) echo 4 ;;
        running)    echo 3 ;;
        input)      echo 2 ;;
        done)       echo 1 ;;
        *)          echo 0 ;;
    esac
}

claude_pane_opt() {
    tmux show-options -pqv -t "${2:-$TMUX_PANE}" "$1" 2>/dev/null
}

claude_pane_state() {
    claude_pane_opt @claude-pane-state "${1:-$TMUX_PANE}"
}

# Recompute the window option from the panes that still exist. A pane that
# went away takes its state with it, so this also garbage-collects.
claude_sync_window() {
    local panes pane state rank best=0 winner=""
    panes=$(tmux list-panes -F '#{pane_id}' -t "$TMUX_PANE" 2>/dev/null) || return 0
    # Read line by line rather than looping over an unquoted $panes: zsh does
    # not word-split parameters, so that form hands the whole list over as a
    # single bogus pane id and the window ends up cleared. Hooks run under
    # bash, but this file gets sourced by hand from a shell prompt too.
    while IFS= read -r pane; do
        [ -n "$pane" ] || continue
        state=$(claude_pane_state "$pane")
        rank=$(claude_state_rank "$state")
        if [ "$rank" -gt "$best" ]; then
            best="$rank"
            winner="$state"
        fi
    done <<EOF
$panes
EOF
    tmux set-option -w -t "$TMUX_PANE" @claude-state "$winner" 2>/dev/null
    tmux refresh-client -S 2>/dev/null
}

claude_set_state() {
    [ -n "$TMUX" ] || return 0
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-state "$1" 2>/dev/null
    claude_sync_window
}

# Activity fingerprint: what Claude is doing and when it last proved it.
# notify.sh needs this to tell "still working" from "blocked on you" — the
# same Notification text arrives in both cases.
claude_mark_activity() {
    [ -n "$TMUX" ] || return 0
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-phase "$1" 2>/dev/null
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-tool "${2:-}" 2>/dev/null
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-beat "$(date +%s)" 2>/dev/null
}

claude_clear_pane() {
    [ -n "$TMUX" ] || return 0
    local opt
    for opt in @claude-pane-state @claude-pane-phase @claude-pane-tool @claude-pane-beat; do
        tmux set-option -p -u -t "$TMUX_PANE" "$opt" 2>/dev/null
    done
    claude_sync_window
}
