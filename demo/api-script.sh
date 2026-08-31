#!/bin/bash
# The api window's screen. Static except for two beats that sync with the
# driver in drive.sh: the permission dialog is already waiting when the
# recording switches here (~6s), and the approval swap (~8s) is the one pane
# change the viewer sees — everything else that moves is the tab bar.
clear; tput civis
printf '\n \033[2m❯\033[0m claude\n \033[2m⏺ Bash(npm test)…\033[0m\n'
sleep 3.5
printf ' \033[33m⚠ needs permission:\033[0m npm run db:reset   \033[2m1. Yes   2. No\033[0m\n'
sleep 4.5
printf ' \033[2m❯ 1\033[0m\n \033[2m⏺ Bash(npm run db:reset)…\033[0m\n'
sleep 600
