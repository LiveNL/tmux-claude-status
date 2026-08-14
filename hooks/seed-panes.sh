#!/bin/bash
# Give every pane that holds a Claude session an indicator, and take it away
# from every pane that does not.
#
# Hooks are the only thing that knows what a session is *doing*, and they can
# only report from the moment they start firing. Two gaps follow from that, and
# both are answered by a fact rather than a guess:
#
#   a pane with a live Claude process and no state yet — a session that has not
#   fired an event since it started is waiting on you, which is what a session
#   does before its first prompt, so the tab says so;
#
#   a pane with state but no Claude process — the session exited and the tab
#   would otherwise keep its last glyph forever.
#
# Nothing here reads the screen and nothing overrules a state a hook has set.
# Presence of the process is checked against the process tree, so it holds for
# a session under a wrapper, under a pty, or started by hand.
#
#   seed-panes.sh              one pass
#   seed-panes.sh --dry-run    report only
#   seed-panes.sh --watch [n]  keep panes seeded, default every 10s

source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

# Test seam: a file of "pid ppid comm" lines standing in for the live process
# table, so the writing behaviour can be exercised against a known tree.
CLAUDE_PS_TABLE="${CLAUDE_PS_TABLE:-}"

DRY=""
WATCH=""
INTERVAL="${2:-10}"
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
    LOCK="${CLAUDE_SEED_LOCK:-/tmp/claude-seed-panes.lock}"
    if ! mkdir "$LOCK" 2>/dev/null; then
        # The owner writes its pid just after creating the directory, so an
        # empty pid file means "started moments ago", not "died". Reading it
        # once and calling it stale let a second watcher delete a live lock
        # and start alongside the first.
        pid=""
        for _ in 1 2 3 4 5; do
            pid=$(cat "$LOCK/pid" 2>/dev/null)
            [ -n "$pid" ] && break
            sleep 0.2
        done
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

# Which panes hold a Claude session, decided from one snapshot of the process
# table. A session can sit several levels down — a login shell, a `zsh -c` that
# runs it, a wrapper that re-execs it on a pty — so this walks descendants
# rather than looking at the pane's immediate process.
#
# The walk is done here rather than with `pgrep -P` per level: BSD pgrep does
# not reliably list children by parent, and silently returning none made panes
# with a perfectly live session look empty.
# Args: <panes file: "pane_id pane_pid"> [process table file: "pid ppid comm"]
# The table is a parameter so the walk can be exercised against a fabricated
# process tree instead of whatever happens to be running.
panes_with_session() {
    { [ -n "$2" ] && cat "$2" || ps -Ao pid=,ppid=,comm=; } | awk '
        NR == FNR {
            pid = $1; ppid = $2
            cmd = $3
            for (i = 4; i <= NF; i++) cmd = cmd " " $i
            kids[ppid] = kids[ppid] " " pid
            comm[pid] = cmd
            next
        }
        function is_claude(c) {
            return (c ~ /(^|\/)claude$/ || c ~ /\/versions\/[0-9]/ || c ~ /(^|\/)claude-code$/)
        }
        function walk(pid, depth,   n, i, parts) {
            if (depth > 8) return 0
            if (is_claude(comm[pid])) return 1
            n = split(kids[pid], parts, " ")
            for (i = 1; i <= n; i++)
                if (parts[i] != "" && walk(parts[i], depth + 1)) return 1
            return 0
        }
        { print $1, (walk($2, 0) ? "yes" : "no") }
    ' - "$1"
}

seeded=0
cleared=0
kept=0

PANES=$(mktemp)
trap 'rm -f "$PANES"' EXIT
tmux list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null > "$PANES"

while read -r pane verdict; do
    [ -n "$pane" ] || continue
    state=$(claude_pane_state "$pane")
    win=$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}')

    if [ "$verdict" = "yes" ]; then
        if [ -n "$state" ]; then
            kept=$(( kept + 1 ))
            continue
        fi
        printf 'seed    %-16s %-5s (session present, no state yet)\n' "$win" "$pane"
        seeded=$(( seeded + 1 ))
        [ -n "$DRY" ] && continue
        TMUX_PANE="$pane" claude_set_state "input"
    else
        [ -n "$state" ] || continue
        printf 'clear   %-16s %-5s (no session in this pane)\n' "$win" "$pane"
        cleared=$(( cleared + 1 ))
        [ -n "$DRY" ] && continue
        TMUX_PANE="$pane" claude_clear_pane
    fi
done <<EOF
$(panes_with_session "$PANES" "$CLAUDE_PS_TABLE")
EOF

printf '%s %s seeded, %s cleared, %s untouched\n' \
    "${DRY:+dry run:}" "$seeded" "$cleared" "$kept"
