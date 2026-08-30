#!/bin/bash
# What the tab actually draws.
#
# The state can be perfect and the tab still wrong: a format string is a second
# program, and it has broken before — commas inside `#[fg=x,bg=y]` swallowed by
# the `#{?cond,a,b}` separator, a state added to the hooks and never added to
# the format. So expand the real format for every state and read the glyph and
# the colour back out.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
test_server_start
trap test_server_stop EXIT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P=$(t list-panes -t t -F '#{pane_id}' | head -1)
W=$(t list-windows -t t -F '#{window_id}' | head -1)

t source-file "$ROOT/tmux/claude-state.conf"

render() { # state format-option -> expanded text
    t set-option -w -t "$W" @claude-state "$1"
    t set-option -w -t "$W" @claude-spinner "⬢"
    t display-message -p -t "$P" "$(t show-options -gwqv "$2")"
}

# state -> glyph, colour, weight. The table is the specification: a new state
# has to be added here before it can be claimed to work.
SPEC="running:⬢:cyan:bold
input:?:yellow:nobold
permission:!:red:bold
done:✓:green:nobold"

for fmt in window-status-format window-status-current-format; do
    echo "-- $fmt --"
    while IFS=: read -r state glyph colour weight; do
        out=$(render "$state" "$fmt")
        case "$out" in
            *"$glyph"*) pass "$state draws $glyph" ;;
            *)          fail "$state draws no $glyph -> '$out'" ;;
        esac
        case "$out" in
            *"#[fg=$colour]"*) pass "$state is $colour" ;;
            *)                 fail "$state is not $colour -> '$out'" ;;
        esac
        case "$out" in
            *"#[$weight]"*) pass "$state is $weight" ;;
            *)              fail "$state is not $weight -> '$out'" ;;
        esac
    done <<< "$SPEC"

    # Idle draws no glyph at all — and must not accidentally inherit one.
    out=$(render "" "$fmt")
    case "$out" in
        *⬢*|*"?"*|*"!"*|*✓*) fail "idle drew an indicator -> '$out'" ;;
        *)                    pass "idle draws nothing" ;;
    esac

    # An unknown state falls through to the same blank rather than breaking the
    # format — a hook writing a typo must not take the tab bar with it.
    out=$(render "wat" "$fmt")
    case "$out" in
        *⬢*|*"?"*|*"!"*|*✓*) fail "an unknown state drew an indicator -> '$out'" ;;
        "")                   fail "an unknown state emptied the tab" ;;
        *)                    pass "an unknown state renders as idle" ;;
    esac

    # The window still has to be identifiable: index and name survive.
    t set-option -w -t "$W" @claude-state running
    out=$(t display-message -p -t "$P" "$(t show-options -gwqv "$fmt")")
    case "$out" in
        *" 0 "*) pass "the window index survives the indicator" ;;
        *)       fail "no window index in '$out'" ;;
    esac
done

# The spinner is drawn from the option, not hardcoded: whatever frame the
# animation last wrote is what the tab shows.
t set-option -w -t "$W" @claude-state running
t set-option -w -t "$W" @claude-spinner "⬡"
out=$(t display-message -p -t "$P" "$(t show-options -gwqv window-status-format)")
case "$out" in
    *⬡*) pass "the tab draws the current spinner frame" ;;
    *)   fail "the spinner frame is not drawn -> '$out'" ;;
esac

# The format that actually renders on this machine is the user's own, not the
# one this repo ships — and it is the one that broke last time, when commas
# inside a #[fg=x,bg=y] block were eaten by the #{?cond,a,b} separator. Test it
# too when it is there, so a hand-edited tab bar cannot silently stop drawing.
if [ -f "$HOME/.tmux.conf" ] && grep -q '@claude-state' "$HOME/.tmux.conf"; then
    echo "-- ~/.tmux.conf --"
    live=$(mktemp); grep -E '^setw -g window-status(-current)?-format' "$HOME/.tmux.conf" > "$live"
    t source-file "$live"
    rm -f "$live"
    t set-option -w -t "$W" @park ""
    while IFS=: read -r state glyph _ _; do
        for fmt in window-status-format window-status-current-format; do
            out=$(render "$state" "$fmt")
            case "$out" in
                *"$glyph"*) pass "live $fmt draws $state" ;;
                *)          fail "live $fmt drops $state -> '$out'" ;;
            esac
        done
    done <<< "$SPEC"
    # A live format also has to stay readable when there is no Claude at all.
    out=$(render "" window-status-format)
    [ -n "$out" ] && pass "live format still draws an idle tab" || fail "live format renders idle as nothing at all"
    t source-file "$ROOT/tmux/claude-state.conf"
else
    echo "info no @claude-state in ~/.tmux.conf — skipped the live format check"
fi

# The prefix fragment ships separately for people with their own format. It has
# to carry the same four states, or half the README is a lie.
echo "-- claude-state-prefix.txt --"
# Comment lines start with "# "; the format itself also starts with a # — as
# `#{?…` — so strip on the character after it, not on the # alone.
PREFIX=$(grep -vE '^#($|[^{[])' "$ROOT/tmux/claude-state-prefix.txt" | grep -v '^$')
while IFS=: read -r state glyph colour _; do
    t set-option -w -t "$W" @claude-state "$state"
    t set-option -w -t "$W" @claude-spinner "⬢"
    out=$(t display-message -p -t "$P" "$PREFIX")
    case "$out" in
        *"$glyph"*"#[fg=$colour]"*|*"#[fg=$colour]"*"$glyph"*) pass "prefix draws $state as $colour $glyph" ;;
        *) fail "prefix draws $state wrong -> '$out'" ;;
    esac
done <<< "$SPEC"
