#!/bin/bash
# Verify every tab against Claude Code's own account of its sessions.
#
# Claude Code maintains ~/.claude/sessions/<pid>.json for each live CLI
# session: a status of busy | waiting | idle, and the tmux pane the session
# runs in. That file keeps moving through the windows where no hook event
# exists — stop-hook chains, post-Stop continuations, subagents working under
# a finished turn, an Esc that fired nothing — so it is the authority the
# hooks cannot be. Measured before building this: over one 11-hour working
# day the tabs spent 35 minutes wearing a finished colour while the session
# file said busy, one stretch of 203 seconds.
#
# The division of labour stands: hooks paint first (about half a second) and
# carry the meaning Claude does not track — a question is amber, a finished
# turn green, both are "idle" to Claude. This pass only corrects drift:
#
#   file busy     tab settled or red   ->  running   (the work is observable)
#   file waiting  tab anything else    ->  permission (a dialog is up)
#   file idle     tab running or red   ->  input      (missed ending, Esc)
#
# Two grace guards keep the authorities from fighting over an edge: a pane
# whose hook activity is fresher than GRACE seconds is left alone, and so is
# a session file whose status changed less than GRACE seconds ago.
#
#   reconcile-panes.sh              one pass
#   reconcile-panes.sh --watch [n]  keep verifying, default every 3s
#
# The file is internal to Claude Code and undocumented;
# tests/test-session-contract.sh pins the four fields this script reads, so a
# release that changes the shape turns up as a failing suite, not as a tab
# that quietly stops correcting itself.

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"
GRACE="${CLAUDE_RECONCILE_GRACE:-3}"

if [ -z "$TMUX" ]; then
    TMUX=$(tmux display-message -p '#{socket_path},0,0' 2>/dev/null) || {
        echo "no tmux server" >&2
        exit 1
    }
    export TMUX
fi

if [ "${1:-}" = "--watch" ] || [ "${1:-}" = "-w" ]; then
    INTERVAL="${2:-3}"
    LOCK="${CLAUDE_RECONCILE_LOCK:-/tmp/claude-reconcile-panes.lock}"
    if ! mkdir "$LOCK" 2>/dev/null; then
        pid=""
        for _ in 1 2 3 4 5; do
            pid=$(cat "$LOCK/pid" 2>/dev/null)
            [ -n "$pid" ] && break
            sleep 0.2
        done
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "reconciler already running (pid $pid)"
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

command -v jq >/dev/null 2>&1 || exit 0
[ -d "$SESSIONS_DIR" ] || exit 0

now_ms=$(( $(date +%s) * 1000 ))

for f in "$SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r pid status updated tmuxref < <(
        jq -r '[.pid, .status, .statusUpdatedAt, .tmux // ""] | @tsv' "$f" 2>/dev/null
    )
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    # A file whose process is gone is a leftover, not a session.
    kill -0 "$pid" 2>/dev/null || continue
    pane="${tmuxref##*.}"
    case "$pane" in %*) ;; *) continue ;; esac
    state=$(tmux show-options -pqv -t "$pane" @claude-pane-state 2>/dev/null) || continue

    # Fresh edges win, on either side: a hook that just painted knows more
    # than a file poll, and a status that just flipped may not have settled.
    beat=$(tmux show-options -pqv -t "$pane" @claude-pane-beat 2>/dev/null)
    [ -n "$beat" ] && [ $(( $(date +%s) - beat )) -lt "$GRACE" ] && continue
    case "$updated" in
        ''|*[!0-9]*) ;; # unparseable: fall through, the contract test will complain
        *) [ $(( now_ms - updated )) -lt $(( GRACE * 1000 )) ] && continue ;;
    esac

    case "$status" in
        busy)
            # An unanswered question outranks a busy file: subagents keep a
            # session busy while the chat itself waits on you.
            TMUX_PANE="$pane" claude_ask_pending && continue
            case "$state" in
                done|input|permission|"")
                    TMUX_PANE="$pane" claude_clear_settled
                    TMUX_PANE="$pane" claude_mark_activity "reconciled" ""
                    TMUX_PANE="$pane" claude_set_state "running"
                    claude_start_spinner "$pane"
                    ;;
            esac
            ;;
        waiting)
            if [ "$state" != "permission" ]; then
                TMUX_PANE="$pane" claude_mark_activity "permission" ""
                TMUX_PANE="$pane" claude_set_state "permission"
            fi
            ;;
        idle)
            # The session stopped without the tab hearing it end — an Esc, or
            # a Stop that never reached this pane. It awaits you either way.
            case "$state" in
                running|permission)
                    TMUX_PANE="$pane" claude_clear_ask
                    TMUX_PANE="$pane" claude_mark_activity "reconciled" ""
                    TMUX_PANE="$pane" claude_set_settled "input"
                    TMUX_PANE="$pane" claude_set_state "input"
                    ;;
            esac
            ;;
    esac
done

exit 0
