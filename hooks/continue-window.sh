#!/bin/bash
# Fired on PostToolUse. Kept for settings.json files written by earlier installs.
#
# It used to restore "running" itself, which meant it never looked at the tool
# name — and PostToolUse is exactly where an answered question retires its
# latch. busy-window.sh handles the whole event, tool name included, so this
# hands the payload over rather than keeping a second, blinder copy.

payload=$(cat 2>/dev/null)

printf '%s' "$payload" | exec bash "$(dirname "${BASH_SOURCE[0]}")/busy-window.sh"
