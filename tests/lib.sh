#!/bin/bash
# Every test runs against its own tmux server.
#
# Sharing the user's server meant the seeder watching it would clear the state
# off panes a test had just set up — the tests failed on a live system and
# passed on a quiet one, which is the opposite of what they are for.
HOOKS="${HOOKS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks}"
SOCKET="claudehooks-test-$$"

# -f /dev/null: a fresh server reads ~/.tmux.conf, which starts the seeder and
# wires the pane hooks. That seeder would then clear the state off test panes,
# since they hold no Claude session — the tests were fighting a copy of the
# very thing they are testing.
t() { command tmux -f /dev/null -L "$SOCKET" "$@"; }

test_server_start() {
    t kill-server 2>/dev/null
    t new-session -d -s t -x 80 -y 24 -c /tmp
    # Hooks find their server through $TMUX, so point it at this one.
    TMUX=$(t display-message -p '#{socket_path},0,0')
    export TMUX
    source "$HOOKS/lib/state.sh"
}

test_server_stop() { t kill-server 2>/dev/null; }

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; }
check() { # label actual expected
    [ "$2" = "$3" ] && pass "$1 -> '$2'" || fail "$1 -> '$2' (want '$3')"
}
