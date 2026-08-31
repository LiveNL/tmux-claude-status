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

# The panes never show a live shell. The focused window holds the static idle
# chat from pane-script.sh; the background windows hold the same kind of quiet
# mock. Nothing in any pane ever moves — the tab bar is the only animation.
SESSION='clear; tput civis; printf "\n \033[2m❯\033[0m claude\n\n \033[2m⏺ working…\033[0m\n"; sleep 600'

up() {
    t kill-server 2>/dev/null
    t -f /dev/null new-session -d -s work -n api -x 130 -y 8 "bash '$ROOT/demo/api-script.sh'"
    t source-file "$ROOT/demo/theme.conf"
    t set -g base-index 1
    t set -g mouse off

    t new-window -t work -n frontend "sh -c '$SESSION'"
    t new-window -t work -n infra "sh -c '$SESSION'"
    t new-window -t work -n notes "bash '$ROOT/demo/pane-script.sh'"
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
    for tick in $(seq 0 44); do
        # The workflow, not just the lights: you idle in notes, api calls you
        # with a red !, you jump there, approve, jump back — and the rest of
        # the states arrive while you work on. Ticks sync with api-script.sh.
        # Captions are NOT set here: demo/captions.py draws them onto the GIF
        # afterwards, as an overlay that is clearly not part of the terminal.
        # Its time windows mirror these tick numbers — change one, change both.
        case "$tick" in
            1)  state api running; state frontend running; running=(api frontend) ;;
            8)  state api permission; running=(frontend) ;;     # the glance
            12) t select-window -t work:api ;;                  # the jump
            16) state api running; running=(api frontend) ;;    # the approval
            20) t select-window -t work:notes ;;                # the return
            24) state frontend done; running=(api) ;;
            30) state infra input; refresh ;;
            36) state api done; running=() ;;
            43) break ;;
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

# A frozen bar wearing all four states at once, for the README cover.
# demo/cover.tape screenshots it; demo/cover.py writes the title on top.
cover() {
    t kill-server 2>/dev/null
    t -f /dev/null new-session -d -s work -n api -x 130 -y 8 "sh -c 'clear; tput civis; sleep 600'"
    t source-file "$ROOT/demo/theme.conf"
    t set -g base-index 1
    t set -g mouse off
    local w
    for w in frontend infra docs; do
        t new-window -t work -n "$w" "sh -c 'clear; tput civis; sleep 600'"
    done
    t move-window -r -t work
    state api running; spin api "⬢"
    state frontend input
    state infra permission
    state docs done
    t select-window -t work:api
    refresh
}

# One state per segment, separated by one-second idle gaps that demo/minis.py
# splits on — no clock synchronisation, the bar itself marks the cuts.
minis() {
    t kill-server 2>/dev/null
    t -f /dev/null new-session -d -s work -n api -x 130 -y 8 "sh -c '$SESSION'"
    t source-file "$ROOT/demo/theme.conf"
    t set -g base-index 1
    t set -g mouse off
    local w
    for w in frontend infra notes; do
        t new-window -t work -n "$w" "sh -c '$SESSION'"
    done
    t move-window -r -t work
    t select-window -t work:notes

    (
        local phase tick frame=0 glyph
        for phase in running input permission done; do
            state api ""; refresh
            sleep 1
            for tick in $(seq 1 8); do
                frame=$(( 1 - frame ))
                [ "$frame" = 1 ] && glyph="⬢" || glyph="⬡"
                case "$tick" in
                    1) state api running ;;
                    4) [ "$phase" != running ] && state api "$phase" ;;
                esac
                [ "$(t show-options -wqv -t work:api @claude-state)" = "running" ] && spin api "$glyph"
                refresh
                sleep 0.5
            done
        done
        state api ""; refresh
    ) >/dev/null 2>&1 &
    disown 2>/dev/null
    echo "attach with: tmux -L $SOCKET attach -t work"
}

case "${1:-up}" in
    up)    up ;;
    cover) cover; echo "attach with: tmux -L $SOCKET attach -t work" ;;
    minis) minis ;;
    down)  down ;;
    *)     echo "usage: drive.sh up|cover|minis|down" >&2; exit 1 ;;
esac
