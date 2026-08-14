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

# Hooks are meant to inherit TMUX and TMUX_PANE from the session firing them,
# and most do. Some do not: a session that was resumed, or is being driven
# from outside the terminal, runs its hooks with those variables missing, and
# then every write in this file targets nothing at all while the hook still
# reports success. Recover the pane instead of giving up on it.
#
# The session id is the reliable handle — record-session.sh stamps it onto the
# pane at SessionStart — with the working directory as a fallback, and only
# when it identifies exactly one pane. Re-stamp whatever is found so the next
# hook resolves directly.
#
# Returns non-zero when no pane can be identified; callers should exit.
claude_bootstrap() {
    local payload="$1" sid pane stamped cwd hit=""

    if [ -z "$TMUX" ]; then
        TMUX=$(tmux display-message -p '#{socket_path},0,0' 2>/dev/null) || return 1
        export TMUX
    fi

    if [ -n "$TMUX_PANE" ] && tmux display-message -t "$TMUX_PANE" -p '' >/dev/null 2>&1; then
        return 0
    fi

    sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [ -n "$sid" ]; then
        while IFS="	" read -r pane stamped; do
            [ "$stamped" = "$sid" ] || continue
            TMUX_PANE="$pane"
            export TMUX_PANE
            return 0
        done <<EOF
$(tmux list-panes -a -F '#{pane_id}	#{@claude-session}' 2>/dev/null)
EOF
    fi

    # Directory fallback. Two conversations in one checkout are indistinguishable
    # this way, so an ambiguous match is treated as no match — a blank tab beats
    # a confidently wrong one, and the reconciler still repairs it from screen.
    # tmux reports the physical path, so resolve ours the same way — on macOS
    # $PWD is routinely a symlink (/tmp, /var) and would never compare equal.
    local here
    here=$(pwd -P 2>/dev/null) || here="$PWD"
    while IFS="	" read -r pane cwd; do
        [ "$cwd" = "$here" ] || continue
        [ -n "$hit" ] && return 1
        hit="$pane"
    done <<EOF
$(tmux list-panes -a -F '#{pane_id}	#{pane_current_path}' 2>/dev/null)
EOF
    [ -n "$hit" ] || return 1

    TMUX_PANE="$hit"
    export TMUX_PANE
    [ -n "$sid" ] && tmux set-option -p -t "$TMUX_PANE" @claude-session "$sid" 2>/dev/null
    return 0
}

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

# Animate the tab for as long as this pane keeps working.
#
# Parallel tool calls fire hooks concurrently. A read-then-write pidfile loses
# that race and leaks an immortal spinner per call, each forking tmux 3x/sec —
# enough to wedge the single-threaded tmux server overnight. The lock directory
# is created atomically, so exactly one spinner per pane can ever exist and
# every loser simply returns.
claude_start_spinner() {
    local pane="${1:-$TMUX_PANE}" lock
    lock="/tmp/claude-spinner-${pane#%}.lock"

    mkdir "$lock" 2>/dev/null || return 0
    tmux set-option -w -t "$pane" @claude-spinner "⬢" 2>/dev/null

    (
        # Cleanup hangs off EXIT only. A trap on TERM would run the handler and
        # then *resume* the loop, making the spinner unkillable by anything but
        # SIGKILL — so the signal traps exit, which fires the EXIT trap in turn.
        trap 'rm -rf "$lock" 2>/dev/null' EXIT
        trap 'exit 0' INT TERM HUP
        local frames=("⬢" "⬡") i=0 n state
        # Backstop of 4 hours in case the state ever wedges on "running". The
        # old 30-minute cap was shorter than real agent runs, so the loop kept
        # quitting under a live session and froze the tab on a half-lit glyph.
        for (( n = 0; n < 28800; n++ )); do
            sleep 0.5
            # An empty read also covers a pane that has since been closed.
            state=$(tmux show-options -pqv -t "$pane" @claude-pane-state 2>/dev/null)
            case "$state" in
                running|permission) ;;
                *) exit 0 ;;
            esac
            i=$(( 1 - i ))
            tmux set-option -w -t "$pane" @claude-spinner "${frames[$i]}" 2>/dev/null
            tmux refresh-client -S 2>/dev/null
        done
        # Cap reached with the state still running: nothing is coming back for
        # this pane. Clear it so the tab drops to idle instead of freezing.
        TMUX_PANE="$pane" claude_clear_pane
    ) </dev/null >/dev/null 2>&1 &

    echo $! > "$lock/pid" 2>/dev/null
    disown 2>/dev/null
    return 0
}

claude_clear_pane() {
    [ -n "$TMUX" ] || return 0
    local opt
    for opt in @claude-pane-state @claude-pane-phase @claude-pane-tool @claude-pane-beat; do
        tmux set-option -p -u -t "$TMUX_PANE" "$opt" 2>/dev/null
    done
    claude_sync_window
}
