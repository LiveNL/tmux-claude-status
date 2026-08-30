#!/bin/bash
# The spinner: it must run exactly when the tab means work, stop on its own,
# and never exist twice.
#
# A leaked spinner is not cosmetic. Each one forks tmux three times a second,
# and the tmux server is single-threaded — a handful of them left overnight
# wedges the whole session. The lock is what prevents that, so the lock is what
# gets tested here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT

export TMUX

t new-session -d -s anim -x 80 -y 24
WIN=$(t list-windows -t anim -F '#{window_id}' | head -1)
P=$(t list-panes -t "$WIN" -F '#{pane_id}' | head -1)
LOCK="/tmp/claude-spinner-${P#%}.lock"
rm -rf "$LOCK"

frame() { t show-options -wqv -t "$WIN" @claude-spinner; }
spin_procs() { pgrep -fc "claude-spinner-${P#%}" 2>/dev/null || echo 0; }

# Work animates.
TMUX_PANE=$P claude_set_state running
TMUX_PANE=$P claude_start_spinner "$P"
[ -d "$LOCK" ] && pass "running takes the lock" || fail "running started no spinner"
a=$(frame); sleep 0.7; b=$(frame)
[ "$a" != "$b" ] && pass "the frame advances ($a -> $b)" || fail "the frame is frozen on $a"

# Twice is once. Parallel tool calls call this concurrently and each extra loop
# is a permanent tmux fork bomb.
for _ in 1 2 3 4 5; do TMUX_PANE=$P claude_start_spinner "$P" & done
wait
sleep 0.3
n=$(pgrep -f "state.sh" 2>/dev/null | wc -l | tr -d ' ')
[ -d "$LOCK" ] && pass "the lock survives five concurrent starts" || fail "the lock was lost in the race"
pid=$(cat "$LOCK/pid" 2>/dev/null)
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && pass "one live spinner owns it (pid $pid)" \
    || fail "the lock has no live owner"

# A permission dialog keeps animating: the elapsed timer next to it is the
# point, and freezing it read as a hung session.
TMUX_PANE=$P claude_set_state permission
a=$(frame); sleep 0.7; b=$(frame)
[ "$a" != "$b" ] && pass "permission keeps animating" || fail "permission froze the frame"

# Everything else stops it, and cleans up after itself.
TMUX_PANE=$P claude_set_state input
sleep 1.2
[ -d "$LOCK" ] && fail "the spinner outlived the run" || pass "input stops the spinner and drops the lock"
a=$(frame); sleep 0.7
[ "$a" = "$(frame)" ] && pass "a stopped spinner writes nothing more" || fail "the frame moved after the stop"

# And it refuses to start over a tab that does not mean work — the states that
# a latch or a settled turn can produce out from under a caller.
for state in input done "" permission; do
    rm -rf "$LOCK"
    TMUX_PANE=$P claude_set_state "$state"
    TMUX_PANE=$P claude_start_spinner "$P"
    sleep 0.1
    case "$state" in
        permission) [ -d "$LOCK" ] && pass "permission may animate" || fail "permission refused to animate" ;;
        *) [ -d "$LOCK" ] && fail "${state:-idle} started a spinner" || pass "${state:-idle} does not animate" ;;
    esac
done

# Esc fires no hook at all. The spinner is the only thing still awake, so it is
# the one that has to notice — from the transcript, the only place an interrupt
# is recorded.
rm -rf "$LOCK"
TRANSCRIPT=$(mktemp)
TMUX_PANE=$P claude_clear_pane
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","transcript_path":"%s"}' "$TRANSCRIPT" \
    | TMUX_PANE=$P bash "$HOOKS/busy-window.sh"
check "a run with a transcript still animates" "$(TMUX_PANE=$P claude_pane_state)" "running"
printf '{"type":"user","isSidechain":false,"message":"[Request interrupted by user]"}\n' >> "$TRANSCRIPT"
sleep 1.2
check "an interrupt hands the tab back to you" "$(TMUX_PANE=$P claude_pane_state)" "input"
[ -d "$LOCK" ] && fail "the spinner survived the interrupt" || pass "and stops spinning"
# It stays handed back: the agents an interrupted turn leaves behind must not
# quietly restart the tab.
printf '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | TMUX_PANE=$P bash "$HOOKS/busy-window.sh"
check "a stray tool event does not restart it" "$(TMUX_PANE=$P claude_pane_state)" "input"
rm -f "$TRANSCRIPT"

# The end of a run through the real hook: a question must leave nothing spinning.
rm -rf "$LOCK"
TMUX_PANE=$P claude_clear_pane
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' | TMUX_PANE=$P bash "$HOOKS/busy-window.sh"
[ -d "$LOCK" ] && pass "a tool call animates through the hook" || fail "the hook started no spinner"
printf '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' | TMUX_PANE=$P bash "$HOOKS/busy-window.sh"
sleep 1.2
[ -d "$LOCK" ] && fail "the question left a spinner running" || pass "a question stops the animation"

rm -rf "$LOCK"
