#!/bin/bash
# Record real hook payloads as test fixtures.
#
# The tests otherwise run on payloads written by hand, which cannot notice a
# field Claude renames — the handwritten JSON keeps the old name and the suite
# stays green while the tab stops working. These fixtures are the sample of what
# Claude actually sends; tests/test-payload-contract.sh checks them against
# hooks/payload-contract.txt.
#
#   capture-payloads.sh on      start recording into tests/fixtures/
#   capture-payloads.sh off     stop
#   capture-payloads.sh status  what has been captured so far
#
# Recording is per event and first-one-wins, so drive a session through the
# interactions you want covered: type a prompt, let it run a tool, ask something,
# approve a command, let it finish, quit.

set -u
FLAG="/tmp/claude-payload-capture"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${CLAUDE_FIXTURE_DIR:-$ROOT/tests/fixtures}"

case "${1:-status}" in
    on)
        mkdir -p "$DIR"
        printf '%s' "$DIR" > "$FLAG"
        echo "recording into $DIR"
        echo "every hook writes the first payload it sees per event; run 'off' when done"
        ;;
    off)
        rm -f "$FLAG"
        echo "stopped"
        ;;
    status)
        if [ -f "$FLAG" ]; then
            echo "recording into $(cat "$FLAG")"
        else
            echo "not recording"
        fi
        ;;
    *)
        echo "usage: capture-payloads.sh on|off|status" >&2
        exit 2
        ;;
esac

if [ -d "$DIR" ]; then
    echo "captured:"
    for f in "$DIR"/*.json; do
        [ -e "$f" ] || { echo "  (nothing yet)"; break; }
        printf '  %-20s %s\n' "$(basename "$f" .json)" \
            "$(jq -r 'keys | join(", ")' "$f" 2>/dev/null)"
    done
fi
