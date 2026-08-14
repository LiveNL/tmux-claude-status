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
# Seconds a hook fingerprint stays authoritative. Long enough to cover a slow
# tool call or a stop hook that takes its time, short enough that a session
# whose hooks never land is picked up while you are still looking at the tab.
GRACE="${CLAUDE_RECONCILE_GRACE:-90}"
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
    # The working line is "<glyph> <Word>… (<detail>)" and the detail varies
    # wildly: an elapsed clock, a token count with or without the k, or a note
    # that a hook is still running. Anchor on the ellipsis-then-paren shape
    # instead of the detail, and keep the token counter as a second opinion.
    # A finished turn reads "✻ Sautéed for 13s" — no ellipsis, no parenthesis,
    # so it stays out.
    if [ "$want" = "input" ] && echo "$tail" | grep -qE "…[[:space:]]*\(|↓ [0-9.]+k? tokens"; then
        want="running"
    fi
    case "$tail" in
        *"Do you want "*|*"❯ 1. Yes"*) want="permission" ;;
    esac

    have=$(claude_pane_state "$pane")
    win=$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}')

    # Hooks outrank this. They are told what happened; reading a screen is
    # guesswork against a TUI that can restyle itself at any release, so it
    # must never overrule a session whose hooks are demonstrably landing.
    # A fingerprint younger than the grace period is that proof, and it makes
    # the screen reader what it should be: a fallback for sessions whose hooks
    # are missing, disabled, or firing into a scrubbed environment.
    beat=$(claude_pane_opt @claude-pane-beat "$pane")
    phase=$(claude_pane_opt @claude-pane-phase "$pane")
    case "$phase" in
        seed|reconcile|"") ;;   # never came from a hook — no proof of anything
        *)
            if [ $(( $(date +%s) - ${beat:-0} )) -lt "$GRACE" ]; then
                printf 'keep    %-16s %-5s %s (hooks live)\n' "$win" "$pane" "${have:--}"
                kept=$(( kept + 1 ))
                continue
            fi
            ;;
    esac

    # A live spinner used to veto any downgrade here, on the reasoning that
    # hooks see tool boundaries the screen does not. It made "running" a state
    # nothing could leave: the spinner runs *because* the state says running,
    # so the veto kept alive precisely the condition it was reading as proof.
    # The hook-freshness gate above is the honest version of that idea — it
    # asks whether a hook actually reported something recently.

    if [ "$have" = "$want" ]; then
        printf 'keep    %-16s %-5s %s\n' "$win" "$pane" "$want"
        kept=$(( kept + 1 ))
        continue
    fi

    printf 'repair  %-16s %-5s %s -> %s\n' "$win" "$pane" "${have:-none}" "$want"
    changed=$(( changed + 1 ))
    [ -n "$DRY" ] && continue

    TMUX_PANE="$pane" claude_set_state "$want"
    # A tab that says running must also animate; without a hook-spawned
    # spinner it would sit on a dead glyph.
    [ "$want" = "running" ] && claude_start_spinner "$pane"
    # Only stamp the fingerprint when there is none: a real hook's timestamp
    # is better evidence than this one, and notify.sh reads it to decide
    # whether a run has stalled.
    [ -n "$(claude_pane_opt @claude-pane-beat "$pane")" ] || \
        TMUX_PANE="$pane" claude_mark_activity "reconcile" ""
done < <(tmux list-panes -a -F '#{pane_id}')

[ -n "$DRY" ] && echo "dry run: $changed would change, $kept already correct" \
              || echo "repaired $changed, $kept already correct"
