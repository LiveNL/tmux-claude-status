#!/bin/bash
# The payload fields, checked against payloads Claude actually sent.
#
# Every other suite feeds these hooks JSON written by hand. That can prove the
# logic and never notice a rename: if `transcript_path` became `transcriptPath`
# tomorrow, the handwritten payloads would keep the old name, the suite would
# stay green, and the only place it showed up would be your tab bar. So this
# one reads hooks/payload-contract.txt and holds it against fixtures captured
# from a real session (hooks/capture-payloads.sh on).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="$ROOT/hooks/payload-contract.txt"
FIXTURES="${CLAUDE_FIXTURE_DIR:-$ROOT/tests/fixtures}"

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; }

rows=$(grep -vE '^[[:space:]]*(#|$)' "$CONTRACT")
[ -n "$rows" ] && pass "contract lists $(printf '%s\n' "$rows" | wc -l | tr -d ' ') field bindings" \
    || fail "contract is empty"

# 1. Every field the contract claims is read must actually be read by that
#    script. Drop a field from a hook and the contract becomes fiction.
while read -r field reader _; do
    [ -n "$field" ] || continue
    if grep -q "$field" "$ROOT/hooks/$reader" 2>/dev/null; then
        pass "$reader reads $field"
    else
        fail "$reader no longer reads $field — contract is stale"
    fi
done <<< "$rows"

# 2. And nothing reads a payload field the contract does not mention.
declared=$(printf '%s\n' "$rows" | awk '{print $1}' | sort -u)
for hook in busy-window.sh notify.sh permission-window.sh reset-window.sh end-window.sh; do
    for field in $(grep -oE '\.[a-z_]+ //' "$ROOT/hooks/$hook" 2>/dev/null | tr -d '. /'); do
        printf '%s\n' "$declared" | grep -qx "$field" \
            || fail "$hook reads undeclared field '$field'"
    done
done
pass "no hook reads a field outside the contract"

# 3. The fixtures. Each is one real payload; the contract says which fields it
#    must carry. A rename shows up here as a missing field.
shopt -s nullglob
found=("$FIXTURES"/*.json)
if [ ${#found[@]} -eq 0 ]; then
    echo "info no fixtures recorded — run 'bash hooks/capture-payloads.sh on', drive a session, then re-run"
else
    for f in "${found[@]}"; do
        event=$(basename "$f" .json)
        keys=$(jq -r 'keys[]' "$f" 2>/dev/null)
        [ -n "$keys" ] || { fail "$event fixture is not readable JSON"; continue; }
        # The event name in the file has to match the one it is filed under.
        [ "$(jq -r '.hook_event_name // empty' "$f")" = "$event" ] \
            && pass "$event fixture is a real $event payload" \
            || fail "$event fixture carries a different hook_event_name"
        while read -r field _ events; do
            [ -n "$field" ] || continue
            case "$events" in
                \*) ;;
                *) printf '%s' ",$events," | grep -q ",$event," || continue ;;
            esac
            printf '%s\n' "$keys" | grep -qx "$field" \
                && pass "$event carries $field" \
                || fail "$event no longer carries '$field' — the hooks read a field Claude no longer sends"
        done <<< "$rows"
    done

    # Which events still have no example. Not a failure: a fresh clone has none,
    # and some events (a permission dialog) only happen when they happen.
    missing=""
    for event in $(grep -vE '^[[:space:]]*(#|$)' "$ROOT/hooks/events.txt" | awk '$2 != "-" {print $1}'); do
        [ -f "$FIXTURES/$event.json" ] || missing="$missing $event"
    done
    [ -n "$missing" ] && echo "info no fixture yet for:$missing" \
        || pass "every handled event has a captured payload"

    # A fixture recorded against a much older Claude proves less. Say so rather
    # than fail — a version bump on its own breaks nothing.
    CLI=$(ls -t "$HOME"/.local/share/claude/versions/* 2>/dev/null | head -1)
    STAMP="$FIXTURES/.captured-with"
    if [ -n "$CLI" ] && [ -f "$STAMP" ]; then
        [ "$(cat "$STAMP")" = "$(basename "$CLI")" ] \
            && pass "fixtures were captured with the installed Claude ($(basename "$CLI"))" \
            || echo "info fixtures captured with $(cat "$STAMP"), running $(basename "$CLI") — recapture to be sure"
    fi
fi
