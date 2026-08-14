#!/bin/bash
# Repair tab indicators from what each pane is actually showing.
#
# Hooks only fire while a session is being driven, so anything that happens
# outside that — a tmux server restart, a resurrect/restore, a session that
# was live before the hooks were installed, a crash mid-run — leaves a pane
# with no state and a blank tab. This walks every pane, reads the Claude TUI
# off the screen, and writes the state that matches it.
#
# Safe to run at any time; it only ever writes what the screen already says.
# Wire it into a restore script, bind it to a key, or run it by hand.
#
#   reconcile-panes.sh            repair every pane once
#   reconcile-panes.sh --dry-run  report without writing
#   reconcile-panes.sh --watch    keep repairing every few seconds
#
# Watch mode exists because hooks are not guaranteed. They can be missing,
# disabled per project, or silently fail to reach tmux, and then a tab lies
# until someone notices. Reading the screen needs nothing from the session.

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

DRY=""
WATCH=""
INTERVAL="${2:-3}"
case "$1" in
    --dry-run|-n) DRY=1 ;;
    --watch|-w)   WATCH=1 ;;
esac

if [ -z "$TMUX" ]; then
    TMUX=$(tmux display-message -p '#{socket_path},0,0' 2>/dev/null) || {
        echo "no tmux server" >&2
        exit 1
    }
    export TMUX
fi

if [ -n "$WATCH" ]; then
    # One watcher per machine. The lock is a directory because creating one is
    # atomic, so two `--watch` starts cannot race into a pair of loops.
    LOCK=/tmp/claude-reconcile-watch.lock
    if ! mkdir "$LOCK" 2>/dev/null; then
        pid=$(cat "$LOCK/pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "watcher already running (pid $pid)"
            exit 0
        fi
        rm -rf "$LOCK" && mkdir "$LOCK" 2>/dev/null || exit 1
    fi
    trap 'rm -rf "$LOCK" 2>/dev/null' EXIT
    trap 'exit 0' INT TERM HUP
    echo $$ > "$LOCK/pid"

    self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
    while :; do
        bash "$self" >/dev/null 2>&1
        sleep "$INTERVAL"
    done
fi

changed=0
kept=0

while IFS= read -r pane; do
    [ -n "$pane" ] || continue

    # Never read the pane this is running in: its screen holds this script's
    # own output, so the prompts and markers being matched for turn up in the
    # capture and the pane misreads itself.
    [ "$pane" = "$TMUX_PANE" ] && continue

    body=$(tmux capture-pane -p -t "$pane" 2>/dev/null)

    # Is a Claude TUI on this screen at all? The footer hints are the most
    # reliable tell — a plain shell pane has none of them.
    case "$body" in
        *"for shortcuts"*|*"esc to interrupt"*|*"mode on"*|*"bypass permissions"*) ;;
        # A tall permission dialog can push the footer off screen, so the
        # dialog itself has to count as evidence of a session too.
        *"Do you want "*|*"Esc to cancel"*) ;;
        *) continue ;;
    esac

    # Classify from the bottom of the screen only. Claude draws its live
    # state — working line, permission dialog, prompt box — directly above
    # the footer, while the transcript above can hold any amount of text
    # that merely quotes those markers. Matching the whole screen read a
    # finished session as running off a scrolled-back working line.
    tail=$(echo "$body" | grep -vE '^\s*$' | tail -8)

    want="input"
    case "$tail" in
        *"esc to interrupt"*|*"ctrl+b to run in background"*) want="running" ;;
    esac
    if [ "$want" = "input" ] && echo "$tail" | grep -qE "…\s*\([0-9]+[ms]|↓ [0-9.]+k tokens"; then
        want="running"
    fi
    case "$tail" in
        *"Do you want "*|*"❯ 1. Yes"*) want="permission" ;;
    esac

    # A run is proved by a live spinner, not by a glyph. Without one, only a
    # fresh fingerprint makes "running" credible — otherwise this is a idle
    # session wearing a stale working line, and calling it running would
    # freeze the tab there until the session is next driven.
    if [ "$want" = "running" ] && [ ! -d "/tmp/claude-spinner-${pane#%}.lock" ]; then
        beat=$(claude_pane_opt @claude-pane-beat "$pane")
        [ $(( $(date +%s) - ${beat:-0} )) -gt 120 ] && want="input"
    fi

    have=$(claude_pane_state "$pane")
    win=$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}')

    # A live spinner means the hooks currently believe this pane is working,
    # and they see tool boundaries the screen does not. Never let a screen
    # reading retire a run they are still tracking.
    if [ "$have" = "running" ] && [ "$want" != "permission" ] \
       && [ -d "/tmp/claude-spinner-${pane#%}.lock" ]; then
        printf 'keep    %-16s %-5s running (spinner alive)\n' "$win" "$pane"
        kept=$(( kept + 1 ))
        continue
    fi

    if [ "$have" = "$want" ]; then
        printf 'keep    %-16s %-5s %s\n' "$win" "$pane" "$want"
        kept=$(( kept + 1 ))
        continue
    fi

    printf 'repair  %-16s %-5s %s -> %s\n' "$win" "$pane" "${have:-none}" "$want"
    changed=$(( changed + 1 ))
    [ -n "$DRY" ] && continue

    TMUX_PANE="$pane" claude_set_state "$want"
    # Only stamp the fingerprint when there is none: a real hook's timestamp
    # is better evidence than this one, and notify.sh reads it to decide
    # whether a run has stalled.
    [ -n "$(claude_pane_opt @claude-pane-beat "$pane")" ] || \
        TMUX_PANE="$pane" claude_mark_activity "reconcile" ""
done < <(tmux list-panes -a -F '#{pane_id}')

[ -n "$DRY" ] && echo "dry run: $changed would change, $kept already correct" \
              || echo "repaired $changed, $kept already correct"
