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

# A hook may only touch a tab when it can name its pane with certainty.
#
# TMUX_PANE is that certainty: the session inherited it from the pane it runs
# in. Everything else that was tried here — matching the working directory, or
# the text of the last reply against what each pane showed — was inference, and
# inference put wrong glyphs on tabs.
#
# The hooks that arrive without it are not tabs at all. Background and forked
# sessions run under the daemon (`claude --bg-pty-host`), whose process tree
# never touches tmux; they fire the same events as any session, and attributing
# those to a pane meant an agent could drive a tab it does not own. They are
# dropped here instead.
#
# Returns non-zero when this hook has no pane; callers exit on that.
claude_bootstrap() {
    if [ -z "$TMUX" ]; then
        TMUX=$(tmux display-message -p '#{socket_path},0,0' 2>/dev/null) || return 1
        export TMUX
    fi
    [ -n "$TMUX_PANE" ] || return 1
    # The pane can be gone: a window closed while its session lived on, or an
    # id inherited from a pane that no longer exists.
    tmux display-message -t "$TMUX_PANE" -p '' >/dev/null 2>&1 || return 1
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
    [ -n "$TMUX_PANE" ] || return 1
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
    # tmux resolves an empty target to the active pane, so a caller that lost
    # its pane id would silently rewrite whichever tab happens to be focused.
    [ -n "$TMUX_PANE" ] || return 1
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-state "$1" 2>/dev/null
    claude_sync_window
}

# Activity fingerprint: what Claude is doing and when it last proved it.
# notify.sh needs this to tell "still working" from "blocked on you" — the
# same Notification text arrives in both cases.
claude_mark_activity() {
    [ -n "$TMUX" ] || return 0
    [ -n "$TMUX_PANE" ] || return 1
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
    [ -n "$TMUX_PANE" ] || return 1
    local opt
    for opt in @claude-pane-state @claude-pane-phase @claude-pane-tool @claude-pane-beat; do
        tmux set-option -p -u -t "$TMUX_PANE" "$opt" 2>/dev/null
    done
    claude_sync_window
}
