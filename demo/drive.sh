#!/bin/bash
# Stage the demo GIF: a real tmux server running the state format, with a
# driver flipping window states on a timeline the way live hooks would. No
# Claude session is involved — the recording is about the tab bar, and the
# states are set through the same options the hooks write.
#
#   demo/drive.sh up      build the session on socket "claude-demo" and start the driver
#   demo/drive.sh down    tear it all down
#
# Record with vhs (brew install vhs):  vhs demo/demo.tape

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET=claude-demo

t() { command tmux -L "$SOCKET" "$@"; }

# The pane never shows a shell: each window runs a printer that draws its
# content and sleeps, so no prompt and no cursor ends up in the recording.
LEGEND='clear; tput civis; printf "\n\n   \033[2mfour Claude Code sessions — the tab bar tracks each one\033[0m\n\n   \033[1;34m⬢ working\033[0m    \033[1;33m? waiting on you\033[0m    \033[1;31m! permission\033[0m    \033[32m✓ done\033[0m\n"; sleep 600'
BLANK='clear; tput civis; sleep 600'
API='clear; tput civis; printf "\n\n   \033[32m✓\033[0m \033[2mapi — turn finished, answer waiting in the transcript\033[0m\n"; sleep 600'

up() {
    t kill-server 2>/dev/null
    t -f /dev/null new-session -d -s work -n api -x 130 -y 12 "sh -c '$API'"
    t source-file "$ROOT/demo/theme.conf"
    t set -g base-index 1
    t set -g mouse off

    t new-window -t work -n frontend "sh -c '$BLANK'"
    t new-window -t work -n infra "sh -c '$BLANK'"
    t new-window -t work -n notes "sh -c '$LEGEND'"
    t move-window -r -t work
    t select-window -t work:notes

    ( driver ) >/dev/null 2>&1 &
    disown 2>/dev/null
    echo "attach with: tmux -L $SOCKET attach -t work"
}

state()   { t setw -t "work:$1" @claude-state "$2" 2>/dev/null; }
spin()    { t setw -t "work:$1" @claude-spinner "$2" 2>/dev/null; }
refresh() { t refresh-client -S 2>/dev/null; }

driver() {
    local tick frame=0 glyph
    # 0.5s ticks. Spinner advances every tick on every running window; the
    # timeline flips states at fixed ticks, ending on a bar that shows all four.
    local -a running=()
    for tick in $(seq 0 40); do
        case "$tick" in
            1)  state api running; running=(api) ;;
            5)  state frontend running; running=(api frontend) ;;
            9)  state api permission; running=(frontend) ;;     # api wants approval
            15) state infra input; refresh ;;                   # infra asked a question
            19) state api running; running=(api frontend) ;;    # approval given
            25) state frontend done; running=(api) ;;           # frontend finished
            31) state api done; running=() ;;                   # api finished
            33) t select-window -t work:api ;;                  # you go read it
            39) break ;;
        esac
        frame=$(( 1 - frame ))
        [ "$frame" = 1 ] && glyph="⬢" || glyph="⬡"
        local w
        for w in "${running[@]:-}"; do
            [ -n "$w" ] && spin "$w" "$glyph"
        done
        refresh
        sleep 0.5
    done
}

down() { t kill-server 2>/dev/null; }

case "${1:-up}" in
    up)   up ;;
    down) down ;;
    *)    echo "usage: drive.sh up|down" >&2; exit 1 ;;
esac
