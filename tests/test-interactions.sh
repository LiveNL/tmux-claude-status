#!/bin/bash
# Every way a chat can move, and what the tab must say afterwards.
#
# The table below is the specification. Each row is a sequence of real hook
# events fed to the real scripts, and the state the pane must end on — checked
# together with the glyph the shipped tmux format draws for it, so "the state
# was right but the tab was wrong" cannot pass.
#
# Rows exist for the three bugs this repo shipped: a subagent repainting an
# unanswered question, a permission that nothing turned back, and a stop hook
# handing the turn back under a green tab. They are the regression net.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap 'rm -f "$TRANSCRIPT"; rm -rf /tmp/claude-spinner-"${P#%}".lock /tmp/claude-permission-"${P#%}".lock /tmp/claude-continue-"${P#%}".lock; test_server_stop' EXIT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TMUX

t new-session -d -s ix -x 80 -y 24
t source-file "$ROOT/tmux/claude-state.conf"
WIN=$(t list-windows -t ix -F '#{window_id}' | head -1)
P=$(t list-panes -t "$WIN" -F '#{pane_id}' | head -1)
TRANSCRIPT=$(mktemp)

# Claude puts transcript_path in every hook payload, and the hooks now rely on
# it — the spinner reads it to notice an interrupt. Add it here too, or the
# harness would be testing a payload Claude never sends.
hook() {
    local body="$2"
    case "$body" in
        \{*) body=$(printf '%s' "$body" | jq -c --arg t "$TRANSCRIPT" \
                    '. + {transcript_path: (.transcript_path // $t)}' 2>/dev/null || printf '%s' "$2") ;;
    esac
    printf '%s' "$body" | TMUX_PANE="$P" bash "$HOOKS/$1"
}

# One verb per thing a chat can do. Everything a subagent does arrives as the
# same events as the main thread — that is precisely why the latches exist — so
# there is no separate verb for it: `tool` is both.
step() {
    local verb="${1%%:*}" arg=""
    case "$1" in *:*) arg="${1#*:}" ;; esac
    case "$verb" in
        start)    hook reset-window.sh '{"hook_event_name":"SessionStart"}' ;;
        end)      hook end-window.sh '{"hook_event_name":"SessionEnd"}' ;;
        prompt)   hook busy-window.sh '{"hook_event_name":"UserPromptSubmit"}' ;;
        tool)     hook busy-window.sh "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"${arg:-Bash}\"}" ;;
        esc)      printf '{"type":"user","isSidechain":false,"message":"[Request interrupted by user]"}\n' >> "$TRANSCRIPT" ;;
        done_)    hook busy-window.sh "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"${arg:-Bash}\"}" ;;
        legacy)   hook continue-window.sh "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"${arg:-Bash}\"}" ;;
        ask)      hook busy-window.sh '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' ;;
        answer)   hook busy-window.sh '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}' ;;
        plan)     hook busy-window.sh '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}' ;;
        approve)  hook busy-window.sh '{"hook_event_name":"PostToolUse","tool_name":"ExitPlanMode"}' ;;
        compact)  hook busy-window.sh '{"hook_event_name":"PreCompact"}' ;;
        perm)     hook permission-window.sh '{"hook_event_name":"PermissionRequest"}' ;;
        stop)     hook notify.sh "{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"${arg:-Done.}\",\"transcript_path\":\"$TRANSCRIPT\"}" ;;
        notify)   hook notify.sh "{\"hook_event_name\":\"Notification\",\"message\":\"${arg:-Claude is waiting for your input}\"}" ;;
        garbage)  hook notify.sh 'not json at all' ;;
        # The main thread writing again is a turn that did not end; a sidechain
        # write is a subagent that outlived it.
        write)    printf '{"isSidechain":false,"type":"assistant"}\n' >> "$TRANSCRIPT" ;;
        sidewrite) printf '{"isSidechain":true,"type":"assistant"}\n' >> "$TRANSCRIPT" ;;
        stale)    TMUX_PANE=$P tmux set-option -p -t "$P" @claude-pane-beat "$(( $(date +%s) - 400 ))" ;;
        wait)     sleep "${arg:-1.2}" ;;
        *)        echo "FAIL unknown verb '$1'"; return 1 ;;
    esac
}

# Running has two glyphs, because it animates — either frame proves the tab.
glyphs_for() {
    case "$1" in
        running) printf '⬢ ⬡' ;; input) printf '?' ;;
        permission) printf '!' ;; done) printf '✓' ;;
        *) printf '' ;;
    esac
}

drawn_glyph() { # drawn-text glyph...
    local drawn="$1" g; shift
    for g in "$@"; do
        [ "${drawn#*"$g"}" != "$drawn" ] && return 0
    done
    return 1
}

# Args: name expected-state step...
scenario() {
    local name="$1" want="$2"; shift 2
    TMUX_PANE=$P claude_clear_pane
    # Kill the previous row's watchers rather than only unlinking their locks:
    # an orphaned loop holds a stale transcript baseline and would keep the next
    # row from starting a watcher of its own.
    local lock pid
    for lock in spinner permission continue; do
        lock="/tmp/claude-$lock-${P#%}.lock"
        pid=$(cat "$lock/pid" 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        rm -rf "$lock"
    done
    : > "$TRANSCRIPT"
    # A hook's exit status is not the assertion — the pane is. Only an unknown
    # verb (a typo in the table below) aborts the row.
    for s in "$@"; do
        case "$s" in
            start|end|prompt|tool*|esc|done_*|legacy*|ask|answer|plan|approve|compact|perm|stop*|notify*|garbage|write|sidewrite|stale|wait*) step "$s" ;;
            *) fail "$name uses unknown verb '$s'"; return ;;
        esac
    done
    local got fmt drawn glyphs
    got=$(TMUX_PANE=$P claude_pane_state)
    fmt=$(t show-options -gwqv window-status-format)
    drawn=$(t display-message -p -t "$P" "$fmt")
    read -ra glyphs <<< "$(glyphs_for "$want")"
    if [ "$got" != "$want" ]; then
        fail "$name -> '$got' (want '$want')"
    elif [ ${#glyphs[@]} -gt 0 ] && ! drawn_glyph "$drawn" "${glyphs[@]}"; then
        fail "$name is '$got' but the tab draws no ${glyphs[0]} -> '$drawn'"
    else
        pass "$name -> $got${glyphs[0]:+ ${glyphs[0]}}"
    fi
}

echo "-- the ordinary turn --"
scenario "a session opens waiting on you"        input   start
scenario "a prompt starts work"                 running start prompt
scenario "a tool call is work"                  running start prompt tool
scenario "so is the end of one"                 running start prompt tool done_
scenario "the legacy PostToolUse hook agrees"   running start prompt tool legacy
scenario "compacting is work too"               running start prompt compact
scenario "a statement finishes green"           done    start prompt tool done_ "stop:All set."
scenario "a question finishes amber"            input   start prompt "stop:Which one?"
scenario "so does a Next step line"             input   start prompt $'stop:Fixed it.\\n**Next step:** say go'
scenario "and the next prompt runs again"       running start prompt "stop:All set." prompt

echo "-- questions --"
scenario "a question waits on you"              input   start prompt ask
scenario "answering resumes"                    running start prompt ask answer
scenario "a plan waits on you"                  input   start prompt plan
scenario "approving resumes"                    running start prompt plan approve
scenario "escaping leaves it until you type"    input   start prompt ask tool done_
scenario "typing releases it"                   running start prompt ask prompt
scenario "stop releases it"                     done    start prompt ask "stop:All set."
# The bug: a subagent's tool boundary landing on the pane under an open question.
scenario "a subagent cannot steal a question"   input   start prompt ask tool done_ tool
scenario "nor can a legacy PostToolUse"         input   start prompt ask legacy

echo "-- permission --"
scenario "a dialog turns the tab red"           permission start prompt perm
scenario "a grant turns it back"                running start prompt perm "tool:Bash" wait
scenario "a queued second dialog stays red"     permission start prompt perm wait:0.4 perm wait
scenario "the notification also paints red"     permission start prompt "notify:Claude needs your permission"
scenario "and that red comes back too"          running start prompt "notify:Claude needs your permission" "tool:Bash" wait
scenario "a grant under a question returns amber" input start prompt ask perm "tool:Bash" wait

echo "-- notifications --"
scenario "a live run ignores the idle nudge"    running start prompt tool notify
scenario "a stalled run believes it"            input   start prompt tool stale notify
scenario "a finished turn stays finished"       done    start prompt "stop:All set." notify
scenario "an unparsable payload clears the tab" ""      start prompt tool garbage

echo "-- after the turn --"
# The bug: agents outliving the turn, repainting a tab you are meant to read.
scenario "subagents do not un-finish a turn"    done    start prompt "stop:All set." tool done_ tool
scenario "nor un-answer a question"             input   start prompt "stop:Which one?" tool done_
scenario "nor does a late compaction"           done    start prompt "stop:All set." compact
scenario "a sidechain write is not the chat"    done    start prompt "stop:All set." sidewrite sidewrite wait
# The bug: a stop hook handing the turn straight back under a green tab.
scenario "a continuation turns it back"         running start prompt "stop:All set." write wait
scenario "even from an amber tab"               running start prompt "stop:Which one?" write wait
scenario "and the next stop settles it again"   done    start prompt "stop:All set." write wait "stop:Really done."

echo "-- interrupted --"
# Esc fires no hook. The spinner reads the transcript, which is the only record.
scenario "esc hands the tab back to you"        input   start prompt tool esc wait
scenario "and nothing restarts it behind you"   input   start prompt tool esc wait done_
scenario "until you type again"                 running start prompt tool esc wait prompt

echo "-- two sessions in one window --"
# Split panes share a tab, so the tab shows the most urgent of them. The pane
# that finishes must not clear the tab of the one still working.
B=$(t split-window -t "$WIN" -d -P -F '#{pane_id}')
win_draws() { # label state
    local drawn glyphs
    drawn=$(t display-message -p -t "$P" "$(t show-options -gwqv window-status-format)")
    read -ra glyphs <<< "$(glyphs_for "$2")"
    drawn_glyph "$drawn" "${glyphs[@]}" && pass "$1 -> $2 ${glyphs[0]}" \
        || fail "$1 drew '$drawn', wanted $2"
}
TMUX_PANE=$P claude_clear_pane; TMUX_PANE=$B claude_clear_pane
TMUX_PANE=$P claude_set_state running; TMUX_PANE=$B claude_set_state done
win_draws "a working pane beats a finished one" running
TMUX_PANE=$B claude_set_state permission
win_draws "a dialog beats work" permission
TMUX_PANE=$B claude_clear_pane
win_draws "and clearing it hands the tab back" running
TMUX_PANE=$P claude_clear_pane
t kill-pane -t "$B"
TMUX_PANE=$P claude_sync_window

echo "-- the session itself --"
scenario "a session ending clears the tab"      ""      start prompt tool end
scenario "even mid-question"                    ""      start prompt ask end
scenario "and reopening starts clean"           input   start prompt ask end start
scenario "a restart owes nothing to the old run" input  start prompt "stop:All set." start
