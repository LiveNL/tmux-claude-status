#!/bin/bash
# Fired on SessionStart.

[ -n "$TMUX" ] || exit 0

tmux set-option -w -t "$TMUX_PANE" @claude-state ""
tmux set-option -w -t "$TMUX_PANE" @claude-spinner "⬢"
tmux refresh-client -S
