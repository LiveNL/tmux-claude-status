#!/bin/bash
# Work out which conversation each pane is running, and stamp it on the pane.
#
# Hooks normally carry TMUX_PANE and need none of this. Some do not: Claude
# hands tool execution to pre-warmed background processes (`claude bg-spare`)
# owned by its daemon, and those inherit the daemon's environment, which has
# never seen tmux. Their hooks arrive with no pane, and a tab driven that way
# never moves.
#
# The payload does carry a session id, so the pane only has to be labelled
# with the same id for the two to meet. That label is derived, not guessed:
#
#   --session-id <uuid> on the pane's process is the id outright;
#   --resume <uuid> names the conversation it continued, and the transcript
#   of the live session quotes that id, so the file that contains it is this
#   pane's session.
#
# A pane that yields no id is left unlabelled rather than approximated.

CLAUDE_PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"

# The directory Claude keeps a project's transcripts in: the absolute path
# with every character that is not a letter, digit or dash turned into a dash.
claude_project_dir() {
    printf '%s/%s' "$CLAUDE_PROJECTS" "$(printf '%s' "$1" | sed 's/[^a-zA-Z0-9-]/-/g')"
}

# Args: <pane claude pid> <pane cwd>. Prints the session id, or nothing.
claude_session_of_pane() {
    local pid="$1" cwd="$2" cmdline sid dir newest

    cmdline=$(ps -p "$pid" -o command= 2>/dev/null) || return 1

    # Started for one specific session: nothing to work out.
    sid=$(printf '%s' "$cmdline" | sed -n 's/.*--session-id \([0-9a-f-]\{36\}\).*/\1/p')
    if [ -n "$sid" ]; then
        printf '%s' "$sid"
        return 0
    fi

    # Resumed: the live transcript is the one quoting the id it resumed from.
    sid=$(printf '%s' "$cmdline" | sed -n 's/.*--resume \([0-9a-f-]\{36\}\).*/\1/p')
    [ -n "$sid" ] || return 1

    dir=$(claude_project_dir "$cwd")
    [ -d "$dir" ] || return 1

    # Newest first: a conversation resumed more than once leaves a trail, and
    # the most recently written file is the session running now.
    newest=$(grep -l -- "$sid" "$dir"/*.jsonl 2>/dev/null | while IFS= read -r f; do
        printf '%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)" "$f"
    done | sort -rn | head -1 | cut -f2)
    [ -n "$newest" ] || return 1

    basename "$newest" .jsonl
}

# Find the pane a session id was stamped on. Exact match only.
claude_pane_of_session() {
    local want="$1" pane stamped
    [ -n "$want" ] || return 1
    while IFS="	" read -r pane stamped; do
        [ "$stamped" = "$want" ] || continue
        printf '%s' "$pane"
        return 0
    done <<EOF
$(tmux list-panes -a -F '#{pane_id}	#{@claude-session}' 2>/dev/null)
EOF
    return 1
}
