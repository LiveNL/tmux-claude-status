#!/bin/bash
# The wiring itself, checked three ways.
#
# Every bug this repo has had came from a state nothing was left to correct.
# The cheapest version of that is an event nobody hooked: Claude gains one, or
# an install stops wiring one, and a tab quietly stops telling the truth. So
# hooks/events.txt is the contract, and this asserts it against install.sh, the
# scripts on disk, and the event names inside the Claude binary.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/hooks/events.txt"
INSTALL="$ROOT/install.sh"

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; }

events=$(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | awk '{print $1}')
[ -n "$events" ] && pass "manifest lists $(printf '%s\n' "$events" | wc -l | tr -d ' ') events" \
    || fail "manifest is empty"

# install.sh names its hooks through jq --arg variables, so resolve those first:
# `--arg busy "bash …/busy-window.sh"` plus `PreToolUse: … command: $busy`.
wired=$(awk '
    /--arg/ { for (i = 1; i < NF; i++) if ($i == "--arg") { var = $(i+1); path = $0
              sub(/.*--arg[[:space:]]+[a-z]+[[:space:]]+"/, "", path); sub(/".*/, "", path)
              n = split(path, parts, "/"); script[var] = parts[n] } }
    /^[[:space:]]*[A-Za-z]+:[[:space:]]*\[\{/ {
        event = $1; sub(/:.*/, "", event)
        if (match($0, /\$[a-z]+\}?\]/)) {
            var = substr($0, RSTART + 1, RLENGTH - 1); gsub(/[}\]]/, "", var)
            print event, script[var]
        }
    }' "$INSTALL")

while read -r event hook _; do
    [ -n "$event" ] || continue
    if [ "$hook" = "-" ]; then
        # An unhandled event must stay unhandled on purpose: if it turns up in
        # install.sh, one of the two is wrong and this says which.
        printf '%s\n' "$wired" | grep -q "^$event " \
            && fail "$event is wired in install.sh but the manifest calls it ignored" \
            || pass "$event deliberately unhandled"
        continue
    fi
    [ -f "$ROOT/hooks/$hook" ] || { fail "$event points at missing $hook"; continue; }
    if printf '%s\n' "$wired" | grep -qx "$event $hook"; then
        pass "$event -> $hook"
    else
        fail "$event -> $hook, but install.sh wires '$(printf '%s\n' "$wired" | awk -v e="$event" '$1 == e {print $2}')'"
    fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST")

# Nothing wired that the manifest does not describe.
while read -r event hook; do
    [ -n "$event" ] || continue
    printf '%s\n' "$events" | grep -qx "$event" \
        || fail "install.sh wires $event -> $hook with no line in the manifest"
done < <(printf '%s\n' "$wired")

# Every hook script the manifest names must survive an install.
for hook in $(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | awk '$2 != "-" {print $2}' | sort -u); do
    grep -q "$hook" "$INSTALL" && pass "$hook is copied by install.sh" \
        || fail "$hook is never installed"
done

# And the other direction: an event Claude emits that the manifest has never
# heard of. The names are read out of the binary, so a Claude release that adds
# one fails here rather than in a month of confused tabs. One pass — the binary
# is ~400MB.
CLI=$(ls -t "$HOME"/.local/share/claude/versions/* 2>/dev/null | head -1)
if [ -n "$CLI" ] && [ -f "$CLI" ]; then
    emitted=$(grep -aoE '"(SessionStart|SessionEnd|UserPromptSubmit|PreToolUse|PostToolUse|PreCompact|PostCompact|PermissionRequest|Notification|Stop|SubagentStop)"' \
        "$CLI" 2>/dev/null | tr -d '"' | sort -u)
    missing=""
    for e in $emitted; do
        printf '%s\n' "$events" | grep -qx "$e" || missing="$missing $e"
    done
    [ -z "$missing" ] && pass "every event $(basename "$CLI") emits is accounted for" \
        || fail "unaccounted events in $(basename "$CLI"):$missing"
else
    echo "info no Claude binary found — skipped the CLI cross-check"
fi
