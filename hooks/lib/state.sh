#!/bin/bash
# Shared state helpers. Sourced by every hook that touches the tab indicator.
#
# State lives on the *pane* (@claude-pane-state); the window option the status
# bar reads (@claude-state) is recomputed as the highest-priority state of any
# pane in that window. Two Claude sessions can then share one tmux window
# without overwriting each other — one finishing no longer clears the tab of
# the one still running — and because a pane option dies with its pane, a
# closed session can never strand a stale indicator on the tab.
#
# Priority: permission > running > input > done > idle.

# A hook may only touch a tab when it can name its pane with certainty.
#
# TMUX_PANE is that certainty: the session inherited it from the pane it runs
# in. Everything else that was tried here — matching the working directory, or
# the text of the last reply against what each pane showed — was inference, and
# inference put wrong glyphs on tabs.
#
# The hooks that arrive without it are not tabs at all. Background and forked
# sessions run under the daemon (`claude --bg-pty-host`), whose process tree
# never touches tmux; they fire the same events as any session, and attributing
# those to a pane meant an agent could drive a tab it does not own. They are
# dropped here instead.
#
# Record one payload per event, for the fixtures the tests replay.
#
# Off unless the flag file exists (hooks/capture-payloads.sh on), because it
# writes on every hook. It lives here rather than in each script because every
# hook hands its payload to claude_bootstrap — one place, no drift.
claude_capture_payload() {
    local flag="/tmp/claude-payload-capture" dir event
    [ -f "$flag" ] || return 0
    dir=$(cat "$flag" 2>/dev/null)
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    event=$(printf '%s' "$1" | jq -r '.hook_event_name // empty' 2>/dev/null)
    [ -n "$event" ] || return 0
    # First one of each event wins: a later, emptier payload of the same kind
    # must not overwrite a full example.
    [ -f "$dir/$event.json" ] && return 0
    # Shape only. A real payload carries the command that ran, the reply that
    # was written and the paths it touched — none of which belongs in a fixture
    # that gets committed. The tests read key names, so every other string goes.
    printf '%s' "$1" \
        | jq --arg e "$event" '
            walk(if type == "string" then "«redacted»" else . end)
            | .hook_event_name = $e' > "$dir/$event.json" 2>/dev/null
}

# Returns non-zero when this hook has no pane; callers exit on that.
claude_bootstrap() {
    claude_capture_payload "$1"
    if [ -z "$TMUX" ]; then
        TMUX=$(tmux display-message -p '#{socket_path},0,0' 2>/dev/null) || return 1
        export TMUX
    fi
    if [ -z "$TMUX_PANE" ]; then
        # Claude runs tools through pre-warmed background processes owned by
        # its daemon, which never inherited tmux. Their hooks carry the same
        # session id as the pane's conversation, and seed-panes.sh stamps that
        # id onto the pane, so the two meet on an exact match — no inference.
        local sid pane
        sid=$(printf '%s' "$1" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        [ -n "$sid" ] || return 1
        source "$(dirname "${BASH_SOURCE[0]}")/session-map.sh"
        pane=$(claude_pane_of_session "$sid") || return 1
        [ -n "$pane" ] || return 1
        TMUX_PANE="$pane"
        export TMUX_PANE
    fi
    # The pane can be gone: a window closed while its session lived on, or an
    # id inherited from a pane that no longer exists.
    tmux display-message -t "$TMUX_PANE" -p '' >/dev/null 2>&1 || return 1
    return 0
}

claude_state_rank() {
    case "$1" in
        permission) echo 4 ;;
        running)    echo 3 ;;
        input)      echo 2 ;;
        done)       echo 1 ;;
        *)          echo 0 ;;
    esac
}

claude_pane_opt() {
    tmux show-options -pqv -t "${2:-$TMUX_PANE}" "$1" 2>/dev/null
}

claude_pane_state() {
    claude_pane_opt @claude-pane-state "${1:-$TMUX_PANE}"
}

# Recompute the window option from the panes that still exist. A pane that
# went away takes its state with it, so this also garbage-collects.
claude_sync_window() {
    local panes pane state rank best=0 winner=""
    [ -n "$TMUX_PANE" ] || return 1
    panes=$(tmux list-panes -F '#{pane_id}' -t "$TMUX_PANE" 2>/dev/null) || return 0
    # Read line by line rather than looping over an unquoted $panes: zsh does
    # not word-split parameters, so that form hands the whole list over as a
    # single bogus pane id and the window ends up cleared. Hooks run under
    # bash, but this file gets sourced by hand from a shell prompt too.
    while IFS= read -r pane; do
        [ -n "$pane" ] || continue
        state=$(claude_pane_state "$pane")
        rank=$(claude_state_rank "$state")
        if [ "$rank" -gt "$best" ]; then
            best="$rank"
            winner="$state"
        fi
    done <<EOF
$panes
EOF
    local prev
    prev=$(tmux show-options -wqv -t "$TMUX_PANE" @claude-state 2>/dev/null)
    tmux set-option -w -t "$TMUX_PANE" @claude-state "$winner" 2>/dev/null
    tmux refresh-client -S 2>/dev/null

    [ "$winner" = "$prev" ] || claude_heal_window_order
}

# A state flip is the cheapest moment to heal the window order. The park engine
# re-sorts only when @park itself changes, so a window opened after a park sits
# left of the parked block until the next park event — the order drifts and
# nothing ever notices. Every real flip is a free tick to check.
#
# Only on a flip, never on every hook: PreToolUse fires per tool call and this
# would otherwise fork a sort per call. sort itself is a no-op when the order
# already matches, so the common case costs one list-windows.
claude_heal_window_order() {
    local park="$HOME/.config/tmux/scripts/tmux-park.sh"
    [ -x "$park" ] || return 0
    # A reorder already in flight owns the indices; a second one racing it would
    # move windows out from under the first pass's scratch range.
    [ "$(tmux show-options -gqv @park-busy 2>/dev/null)" = "1" ] && return 0

    local session
    session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
    [ -n "$session" ] || return 0
    # Detached with every standard stream closed: PreToolUse and UserPromptSubmit
    # are blocking hooks, and a child still holding Claude's pipe open blocks
    # Claude for as long as it runs.
    "$park" sort "$session" >/dev/null 2>&1 </dev/null &
}

# A question stands until it is answered — the latch that says so.
#
# The state slot is one per pane, and a pane is shared: subagents and
# background commands fire their own PreToolUse/PostToolUse against it. Those
# repainted a question's amber tab teal while the question was still on screen,
# and they overwrote the phase/tool fingerprint too, so notify.sh could no
# longer recognise the question either and its stale-run fallback kept quiet.
# The latch survives both, and claude_set_state honours it, so no caller has
# to remember this.
claude_set_ask() {
    [ -n "$TMUX" ] || return 0
    [ -n "$TMUX_PANE" ] || return 1
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-ask "${1:-1}" 2>/dev/null
}

claude_clear_ask() {
    [ -n "$TMUX" ] || return 0
    [ -n "$TMUX_PANE" ] || return 1
    tmux set-option -p -u -t "$TMUX_PANE" @claude-pane-ask 2>/dev/null
}

claude_ask_pending() {
    [ -n "$(claude_pane_opt @claude-pane-ask "${1:-$TMUX_PANE}")" ]
}

# The turn is over — and holds the colour it ended on.
#
# Subagents outlive the turn that spawned them ("← 3 agents" under an empty
# prompt), and their tool calls fire against this pane. Left alone they turned
# a finished tab teal while the chat itself sat idle waiting for you, which is
# the opposite of what the tab is for: it points at where your attention is
# owed. So a settled tab keeps its colour, and only the main thread — a prompt
# you type, or a continuation of the turn itself — can move it.
claude_set_settled() {
    [ -n "$TMUX" ] || return 0
    [ -n "$TMUX_PANE" ] || return 1
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-settled "$1" 2>/dev/null
}

claude_clear_settled() {
    [ -n "$TMUX" ] || return 0
    [ -n "$TMUX_PANE" ] || return 1
    tmux set-option -p -u -t "$TMUX_PANE" @claude-pane-settled 2>/dev/null
}

claude_set_state() {
    [ -n "$TMUX" ] || return 0
    # tmux resolves an empty target to the active pane, so a caller that lost
    # its pane id would silently rewrite whichever tab happens to be focused.
    [ -n "$TMUX_PANE" ] || return 1
    local want="$1" settled
    # Work happening under an open question, or after the turn ended, is real —
    # a subagent still digging, a granted command finishing — but it is not what
    # the tab is for. You are the one being waited on, so that outranks it: the
    # tab holds the question, or the colour the turn ended on. Every other state
    # passes through, permission included: an approval is always yours to give.
    if [ "$want" = "running" ]; then
        if claude_ask_pending; then
            want="input"
        else
            settled=$(claude_pane_opt @claude-pane-settled)
            [ -n "$settled" ] && want="$settled"
        fi
    fi
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-state "$want" 2>/dev/null
    claude_sync_window
}

# Activity fingerprint: what Claude is doing and when it last proved it.
# notify.sh needs this to tell "still working" from "blocked on you" — the
# same Notification text arrives in both cases.
claude_mark_activity() {
    [ -n "$TMUX" ] || return 0
    [ -n "$TMUX_PANE" ] || return 1
    local seq
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-phase "$1" 2>/dev/null
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-tool "${2:-}" 2>/dev/null
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-beat "$(date +%s)" 2>/dev/null
    # The beat answers "how long ago", which needs no better resolution than a
    # second. "Did anything happen since" does: two events inside one second
    # are common — a permission granted and its command starting, say — and on
    # the timestamp alone the second one is invisible. Hence a counter beside
    # it. Concurrent hooks can lose an increment to each other; harmless, since
    # only the fact that it moved is ever read.
    seq=$(claude_pane_opt @claude-pane-seq)
    tmux set-option -p -t "$TMUX_PANE" @claude-pane-seq "$(( ${seq:-0} + 1 ))" 2>/dev/null
}

# Animate the tab for as long as this pane keeps working.
#
# Parallel tool calls fire hooks concurrently. A read-then-write pidfile loses
# that race and leaks an immortal spinner per call, each forking tmux 3x/sec —
# enough to wedge the single-threaded tmux server overnight. The lock directory
# is created atomically, so exactly one spinner per pane can ever exist and
# every loser simply returns.
#
# The second argument is the running session's transcript, and it is how an
# interrupt gets noticed. Pressing Esc fires no hook at all — measured: an
# interrupt at 14:23:08 left no Stop in the log, and the tab spun on until an
# unrelated event happened to correct it. The transcript records it, though, so
# the loop that is already polling watches for it.
claude_start_spinner() {
    local pane="${1:-$TMUX_PANE}" transcript="${2:-}" lock baseline=0
    lock="/tmp/claude-spinner-${pane#%}.lock"

    # Only the two states that mean work animate. Callers ask for a spinner from
    # whatever they believe is happening; the pane knows better, because a
    # question or a finished turn may have refused their "running" a moment ago
    # — and a spinner over a green tab is the tab lying twice.
    case "$(claude_pane_state "$pane")" in
        running|permission) ;;
        *) return 0 ;;
    esac

    mkdir "$lock" 2>/dev/null || return 0
    tmux set-option -w -t "$pane" @claude-spinner "⬢" 2>/dev/null

    # Read the transcript's length here, not in the loop below: forking costs
    # milliseconds, and an interrupt landing inside that window would otherwise
    # be counted as already-seen and never noticed at all.
    [ -n "$transcript" ] && [ -f "$transcript" ] && baseline=$(wc -l < "$transcript" 2>/dev/null)

    (
        # Cleanup hangs off EXIT only. A trap on TERM would run the handler and
        # then *resume* the loop, making the spinner unkillable by anything but
        # SIGKILL — so the signal traps exit, which fires the EXIT trap in turn.
        trap 'rm -rf "$lock" 2>/dev/null' EXIT
        trap 'exit 0' INT TERM HUP
        local frames=("⬢" "⬡") i=0 n state lines
        # Backstop of 4 hours in case the state ever wedges on "running". The
        # old 30-minute cap was shorter than real agent runs, so the loop kept
        # quitting under a live session and froze the tab on a half-lit glyph.
        for (( n = 0; n < 28800; n++ )); do
            sleep 0.5
            # An empty read also covers a pane that has since been closed.
            state=$(tmux show-options -pqv -t "$pane" @claude-pane-state 2>/dev/null)
            case "$state" in
                running|permission) ;;
                *) exit 0 ;;
            esac
            # Esc. No hook fires for it, so the tab would spin over a run that
            # stopped minutes ago; the transcript is where it shows up.
            if [ -n "$transcript" ] && [ -f "$transcript" ]; then
                lines=$(wc -l < "$transcript" 2>/dev/null)
                if [ "${lines:-0}" -gt "$baseline" ] 2>/dev/null; then
                    if tail -n "+$(( baseline + 1 ))" "$transcript" 2>/dev/null \
                        | grep -q 'Request interrupted by user'; then
                        TMUX_PANE="$pane" claude_clear_ask
                        TMUX_PANE="$pane" claude_mark_activity "interrupted" ""
                        TMUX_PANE="$pane" claude_set_settled "input"
                        TMUX_PANE="$pane" claude_set_state "input"
                        exit 0
                    fi
                    baseline="$lines"
                fi
            fi
            i=$(( 1 - i ))
            tmux set-option -w -t "$pane" @claude-spinner "${frames[$i]}" 2>/dev/null
            tmux refresh-client -S 2>/dev/null
        done
        # Cap reached with the state still running: nothing is coming back for
        # this pane. Clear it so the tab drops to idle instead of freezing.
        TMUX_PANE="$pane" claude_clear_pane
    ) </dev/null >/dev/null 2>&1 &

    echo $! > "$lock/pid" 2>/dev/null
    disown 2>/dev/null
    return 0
}

# Turn the red tab back once the dialog has been answered.
#
# Nothing reports the answer: Claude fires no event when you approve, and the
# next one — PostToolUse — only arrives when the command finishes, so a granted
# permission left the tab red for the entire run. Two things prove the answer
# arrived, and the pane needs both:
#
#   - a shell under the session process, since Claude spawns the command only
#     after approval. Blind to subagents, whose commands run under the daemon.
#   - the activity counter moving past where it stood when this watcher armed.
#     Any hook firing means the run resumed, which is the only evidence a
#     subagent's grant ever leaves on the pane.
#
# Marks made by permission-window.sh are skipped: a queued second dialog would
# otherwise read as the first one being answered and clear the tab with the
# prompt still on screen.
#
# One watcher per pane. The lock is reclaimed when its owner is gone, or a
# crashed watcher would lock the pane red for good — the bug this replaced.
claude_arm_permission_watcher() {
    local pane="${1:-$TMUX_PANE}" lock pid baseline
    [ -n "$pane" ] || return 1
    lock="/tmp/claude-permission-${pane#%}.lock"

    if ! mkdir "$lock" 2>/dev/null; then
        pid=$(cat "$lock/pid" 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
        rm -rf "$lock" 2>/dev/null
        mkdir "$lock" 2>/dev/null || return 0
    fi

    baseline=$(claude_pane_opt @claude-pane-seq "$pane")

    (
        trap 'rm -rf "$lock" 2>/dev/null' EXIT
        trap 'exit 0' INT TERM HUP
        local pane_pid state seq phase
        pane_pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
        for _ in $(seq 1 1200); do
            sleep 0.5
            state=$(tmux show-options -pqv -t "$pane" @claude-pane-state 2>/dev/null)
            [ "$state" = "permission" ] || exit 0
            seq=$(tmux show-options -pqv -t "$pane" @claude-pane-seq 2>/dev/null)
            phase=$(tmux show-options -pqv -t "$pane" @claude-pane-phase 2>/dev/null)
            if [ "$phase" != "permission" ] && [ "${seq:-0}" -gt "${baseline:-0}" ] 2>/dev/null; then
                TMUX_PANE="$pane" claude_set_state "running"
                claude_start_spinner "$pane"
                exit 0
            fi
            if claude_pane_executing "$pane_pid"; then
                TMUX_PANE="$pane" claude_set_state "running"
                TMUX_PANE="$pane" claude_mark_activity "tool-start" ""
                claude_start_spinner "$pane"
                exit 0
            fi
        done
    ) </dev/null >/dev/null 2>&1 &

    echo $! > "$lock/pid" 2>/dev/null
    disown 2>/dev/null
    return 0
}

# A Stop is not always the end of the turn.
#
# Claude fires Stop *before* the stop-hook chain runs, and a hook may hand the
# turn back: "running stop hook" stays on screen, tokens keep arriving, and the
# tab had already gone green. Nothing fires again until the next tool call, so
# a continuation that only writes prose left the tab lying for its whole
# length — half a minute of green under a session that was plainly working.
#
# The transcript is the tell: every assistant message is appended as it lands.
# A main-thread assistant line after the Stop means the turn resumed. Sidechain
# lines are skipped — those are the subagents, and they go on working after a
# turn ends without making the chat itself busy.
claude_watch_continuation() {
    local transcript="$1" pane="${2:-$TMUX_PANE}" lock pid baseline
    [ -n "$pane" ] || return 1
    [ -f "$transcript" ] || return 0
    lock="/tmp/claude-continue-${pane#%}.lock"

    if ! mkdir "$lock" 2>/dev/null; then
        pid=$(cat "$lock/pid" 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
        rm -rf "$lock" 2>/dev/null
        mkdir "$lock" 2>/dev/null || return 0
    fi

    baseline=$(wc -l < "$transcript" 2>/dev/null)

    (
        trap 'rm -rf "$lock" 2>/dev/null' EXIT
        trap 'exit 0' INT TERM HUP
        local state lines
        # Two minutes. A continuation announces itself in the first seconds;
        # past that the turn really did end and the green tab was right.
        for _ in $(seq 1 240); do
            sleep 0.5
            state=$(tmux show-options -pqv -t "$pane" @claude-pane-state 2>/dev/null)
            # Anything else means someone with better information already
            # repainted the tab — a new prompt, a tool call, a permission.
            case "$state" in done|input) ;; *) exit 0 ;; esac
            lines=$(wc -l < "$transcript" 2>/dev/null)
            [ "${lines:-0}" -gt "${baseline:-0}" ] 2>/dev/null || continue
            if tail -n "+$(( baseline + 1 ))" "$transcript" 2>/dev/null \
                | grep '"type":"assistant"' | grep -q '"isSidechain":false'; then
                # The turn is demonstrably not over, so it no longer holds a
                # colour — this is the one writer allowed to say so besides a
                # prompt you type.
                TMUX_PANE="$pane" claude_clear_settled
                TMUX_PANE="$pane" claude_set_state "running"
                TMUX_PANE="$pane" claude_mark_activity "continuation" ""
                claude_start_spinner "$pane"
                exit 0
            fi
            # Growth that was not the main thread: bank it so the next pass
            # only reads what is new.
            baseline="$lines"
        done
    ) </dev/null >/dev/null 2>&1 &

    echo $! > "$lock/pid" 2>/dev/null
    disown 2>/dev/null
    return 0
}

# Recompute every window from its panes. A pane that closes takes its state
# with it, but the window option it last published stays behind until someone
# recalculates — a window whose running pane was closed would otherwise keep
# spinning next to its remaining shell.
claude_sync_all_windows() {
    local pane
    while IFS= read -r pane; do
        [ -n "$pane" ] || continue
        TMUX_PANE="$pane" claude_sync_window
    done <<EOF
$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)
EOF
}

claude_clear_pane() {
    [ -n "$TMUX" ] || return 0
    [ -n "$TMUX_PANE" ] || return 1
    local opt
    for opt in @claude-pane-state @claude-pane-phase @claude-pane-tool @claude-pane-beat \
               @claude-pane-seq @claude-pane-ask @claude-pane-settled; do
        tmux set-option -p -u -t "$TMUX_PANE" "$opt" 2>/dev/null
    done
    claude_sync_window
}

# Is this pane's session executing a command right now?
#
# Claude spawns the command only once permission is granted, so a shell running
# under its process is proof the dialog has been answered. An idle session has
# no shell child at all; language servers and caffeinate are not shells and do
# not count. Neither does Claude's own plumbing: the statusline refresh and
# hook scripts run as shell children of the session even while the dialog is
# still open, and mistaking one for the approved command flipped the red tab
# back to running with the prompt still on screen.
# Args: <pane pid>. Optional second arg: a process table for tests.
claude_pane_executing() {
    { [ -n "$2" ] && cat "$2" || ps -Ao pid=,ppid=,comm=,args=; } | awk -v root="$1" '
        { kids[$2] = kids[$2] " " $1; comm[$1] = $3
          line = ""; for (i = 4; i <= NF; i++) line = line " " $i; argv[$1] = line }
        function is_claude(c) { return (c ~ /(^|\/)claude$/ || c ~ /\/versions\/[0-9]/) }
        function is_shell(c)  { return (c ~ /(^|\/)(bash|sh|zsh|dash|fish)$/) }
        function is_plumbing(pid) { return (argv[pid] ~ /statusline\.sh|\/hooks\//) }
        # Below the session process, any shell is a command being run —
        # except plumbing, whose whole subtree is pruned.
        function under_claude(pid, depth,   n, a, i) {
            if (depth > 8) return 0
            if (is_plumbing(pid)) return 0
            if (is_shell(comm[pid])) return 1
            n = split(kids[pid], a, " ")
            for (i = 1; i <= n; i++) if (a[i] != "" && under_claude(a[i], depth + 1)) return 1
            return 0
        }
        function walk(pid, depth,   n, a, i) {
            if (depth > 8) return 0
            if (is_claude(comm[pid])) {
                n = split(kids[pid], a, " ")
                for (i = 1; i <= n; i++) if (a[i] != "" && under_claude(a[i], 0)) return 1
                return 0
            }
            n = split(kids[pid], a, " ")
            for (i = 1; i <= n; i++) if (a[i] != "" && walk(a[i], depth + 1)) return 1
            return 0
        }
        END { exit(walk(root, 0) ? 0 : 1) }'
}
