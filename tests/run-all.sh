#!/bin/bash
# Runs every suite on its own throwaway tmux server. Exits non-zero if any
# assertion failed, so this can gate a commit.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
total=0; failed=0
for t in test-*.sh; do
    out=$(bash "$t" 2>&1)
    ok=$(printf '%s\n' "$out" | grep -c '^ok')
    bad=$(printf '%s\n' "$out" | grep -c '^FAIL')
    total=$(( total + ok + bad )); failed=$(( failed + bad ))
    printf '%-30s %2d passed %2d failed\n' "$t" "$ok" "$bad"
    [ "$bad" -gt 0 ] && printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/    /'
done
printf '\n%d assertions, %d failed\n' "$total" "$failed"
[ "$failed" -eq 0 ]
