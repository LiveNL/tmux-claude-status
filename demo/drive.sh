#!/bin/bash
# Stage the demo GIF: a real tmux server running the shipped status format,
# with a driver flipping window states on a timeline the way live hooks would.
# No Claude session is involved — the recording is about the tab bar, and the
# states are set through the same options the hooks write.
#
#   demo/drive.sh up      build the session on socket "demo" and start the driver
#   demo/drive.sh down    tear it all down
#
# Record with vhs (brew install vhs):  vhs demo/demo.tape

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET=claude-demo

t() { command tmux -L "$SOCKET" "$@"; }

up() {
    t kill-server 2>/dev/null
    t -f /dev/null new-session -d -s work -n api -x 120 -y 18
    t source-file "$ROOT/tmux/claude-state.conf"

    # A quiet bar: the windows are the whole story.
    t set -g status-style "bg=colour235,fg=colour244"
    t set -g status-left "  #S  "
    t set -g status-left-style "bg=colour235,fg=colour109"
    t set -g status-right "  "
    t set -g window-status-separator " "
    t set -g mouse off

    t new-window -t work -n frontend
    t new-window -t work -n infra
    t new-window -t work -n docs

    local w
    for w in api frontend infra docs; do
        t send-keys -t "work:$w" "clear" Enter
    done
    t send-keys -t "work:docs" \
        "clear; printf '\n\n   \033[2mfour Claude sessions, one tab bar — watch below\033[0m\n'" Enter
    t select-window -t work:docs

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
