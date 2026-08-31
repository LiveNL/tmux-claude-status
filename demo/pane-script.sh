#!/bin/bash
# The visible pane: a static, dim, idle Claude chat. It never changes — every
# moving pixel in the recording belongs to the tab bar, which is the product.
clear; tput civis
printf '\n \033[2m❯\033[0m claude\n\n'
printf ' \033[2m╭──────────────────────────────────────────────────────────╮\033[0m\n'
printf ' \033[2m│ >                                                        │\033[0m\n'
printf ' \033[2m╰──────────────────────────────────────────────────────────╯\033[0m\n'
sleep 600
