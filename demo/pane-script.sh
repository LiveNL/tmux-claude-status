#!/bin/bash
# The visible pane's screenplay: a mock Claude chat whose beats line up with
# the states the driver sets on this window, so the recording shows cause
# (the chat) and effect (the tab bar) in one frame. Sleeps here mirror the
# driver's tick numbers in drive.sh — change one, change both.
clear; tput civis
printf '\n \033[2m❯\033[0m claude\n\n'
sleep 0.5
printf ' \033[2m>\033[0m fix the failing auth test\n\n'
printf ' \033[2m⏺ Bash(npm test)…\033[0m\n'
sleep 4
printf '\n \033[33m⚠ needs permission:\033[0m npm run db:reset   \033[2m1. Yes   2. No\033[0m\n'
sleep 5
printf '\n \033[2m❯ 1\033[0m\n\n \033[2m⏺ Bash(npm run db:reset)…\033[0m\n'
sleep 6
printf '\n \033[36m✻\033[0m tests pass — also update the snapshot?\n'
sleep 600
