#!/bin/bash
# Only one watcher may exist. The pid file is written just after the lock
# directory is created, so a challenger that reads it too eagerly must wait
# rather than declare the lock stale and start a second loop.
HOOKS=/Users/livenl/projects/claude-tmux-hooks/hooks
LOCK=/tmp/claude-seed-panes-test.lock
export CLAUDE_SEED_LOCK="$LOCK"
rm -rf "$LOCK"

# Simulate the race directly: a lock directory that exists with no pid yet.
mkdir -p "$LOCK"
( sleep 0.6; echo $$ > "$LOCK/pid" ) &
writer=$!
out=$(CLAUDE_SEED_LOCK="$LOCK" bash "$HOOKS/seed-panes.sh" --watch 60 2>&1)
wait $writer
case "$out" in
    *"already running"*) echo "ok   challenger waits for the pid and backs off" ;;
    *) echo "FAIL challenger did not back off: ${out:-<empty>}" ;;
esac

pkill -f "seed-panes.sh --watch 60" 2>/dev/null
rm -rf "$LOCK"
