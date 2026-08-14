#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT
# What the seeder writes, given a known process tree. It fills blanks, clears
# panes whose session is gone, and never touches a state a hook has set.

t kill-session -t seedtest 2>/dev/null
t new-session -d -s seedtest -x 80 -y 24 -c /tmp
W=$(t list-windows -t seedtest -F '#{window_id}' | head -1)
A=$(t list-panes -t "$W" -F '#{pane_id}' | head -1)
t split-window -t "$W" -d -c /tmp
B=$(t list-panes -t "$W" -F '#{pane_id}' | tail -1)
if [ -z "$A" ] || [ -z "$B" ]; then echo "FAIL harness: no test panes"; exit 1; fi

APID=$(t display-message -p -t "$A" '#{pane_pid}')
BPID=$(t display-message -p -t "$B" '#{pane_pid}')
TABLE=$(mktemp); trap 'rm -f "$TABLE"; t kill-session -t seedtest 2>/dev/null' EXIT

# A holds a session, B is a plain shell.
withsession() { printf '%s 1 /bin/zsh\n%s %s /Users/livenl/.local/bin/claude\n%s 1 /bin/zsh\n' \
    "$APID" "9999" "$APID" "$BPID" > "$TABLE"; }
nosession()   { printf '%s 1 /bin/zsh\n%s 1 /bin/zsh\n' "$APID" "$BPID" > "$TABLE"; }

run() { CLAUDE_PS_TABLE="$TABLE" bash "$HOOKS/seed-panes.sh" >/dev/null 2>&1; }

withsession; run
[ "$(claude_pane_state "$A")" = "input" ] && echo "ok   pane with a session gets an indicator" \
    || echo "FAIL A=$(claude_pane_state "$A")"
[ -z "$(claude_pane_state "$B")" ] && echo "ok   pane without one stays blank" \
    || echo "FAIL B=$(claude_pane_state "$B")"

TMUX_PANE="$A" claude_set_state running; run
[ "$(claude_pane_state "$A")" = "running" ] && echo "ok   hook state is left alone" \
    || echo "FAIL overruled -> $(claude_pane_state "$A")"

nosession; run
[ -z "$(claude_pane_state "$A")" ] && echo "ok   state cleared when the session is gone" \
    || echo "FAIL lingering -> $(claude_pane_state "$A")"
[ -z "$(t show-options -wqv -t "$W" @claude-state)" ] && echo "ok   window falls back to idle" \
    || echo "FAIL window=$(t show-options -wqv -t "$W" @claude-state)"

# A pane that closes takes its state with it; the window must stop showing it.
withsession; run
TMUX_PANE="$A" claude_set_state running
t kill-pane -t "$B" 2>/dev/null
t split-window -t "$W" -d          # keep the window alive with a fresh pane
NEW=$(t list-panes -t "$W" -F '#{pane_id}' | grep -v "^$A$" | head -1)
t kill-pane -t "$A"
run
check "window drops a closed pane's state" "$(t show-options -wqv -t "$W" @claude-state)" ""
