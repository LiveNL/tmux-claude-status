#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT
# End-to-end test of notify.sh state decisions, in a throwaway t session.
# The test window is its own session's current window, so IS_ACTIVE=1 and no
# desktop notification ever fires.

export TMUX
export DEBUG_CLAUDE_HOOKS=1
LOG=/tmp/claude-notify-test.log
rm -f "$LOG"

t new-session -d -s notifytest -x 80 -y 24
WIN=$(t list-windows -t notifytest -F '#{window_id}' | head -1)
P=$(t list-panes -t "$WIN" -F '#{pane_id}' | head -1)

# state, phase, tool, beat-age-seconds
setup() {
    TMUX_PANE="$P" claude_set_state "$1"
    t set-option -p -t "$P" @claude-pane-phase "$2"
    t set-option -p -t "$P" @claude-pane-tool "$3"
    t set-option -p -t "$P" @claude-pane-beat "$(( $(date +%s) - $4 ))"
}

fire() { # event message last_assistant_message
    printf '{"hook_event_name":"%s","message":"%s","last_assistant_message":"%s"}' "$1" "$2" "$3" \
        | TMUX_PANE="$P" bash "$HOOKS/notify.sh"
}

check() { # label expected
    local got
    got=$(TMUX_PANE="$P" claude_pane_state)
    if [ "$got" = "$2" ]; then echo "ok   $1 -> '$got'"; else echo "FAIL $1 -> '$got' (want '$2')"; fi
}

setup running tool-start Bash 5
fire Notification "Claude is waiting for your input"
check "busy run ignores input notification" "running"

setup running tool-start AskUserQuestion 5
fire Notification "Claude is waiting for your input"
check "question tool accepts it" "input"

setup running tool-end "" 400
fire Notification "Claude is waiting for your input"
check "stalled run accepts it" "input"

setup running tool-start Bash 5
fire Notification "Claude needs your permission to use Bash"
check "permission always wins" "permission"

setup permission tool-start Bash 500
fire Notification "Claude is waiting for your input"
check "permission not downgraded" "permission"

setup running tool-end "" 5
fire Stop "" "Fixed the parser. Want me to run the tests?"
check "stop with question" "input"

setup running tool-end "" 5
fire Stop "" "Fixed the parser and pushed the branch."
check "stop without question" "done"

echo "-- debug log --"
cp /tmp/claude-notify.log "$LOG" 2>/dev/null
tail -4 "$LOG" 2>/dev/null | cut -c1-150


# A finished turn keeps its verdict. Claude nudges with an idle notification a
# minute later, and taking that at face value turned every green tab amber.
setup done stop "" 90
fire Notification "Claude is waiting for your input"
check "done survives the idle notification" "done"

setup input stop "" 90
fire Notification "Claude is waiting for your input"
check "input stays input" "input"
