#!/bin/bash
# The walk that decides whether a pane holds a Claude session, exercised
# against a fabricated process tree so the answer never depends on timing or
# on what happens to be running.
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks"
eval "$(sed -n '/^panes_with_session()/,/^}/p' "$HOOKS/seed-panes.sh")"

TABLE=$(mktemp); PANES=$(mktemp)
trap 'rm -f "$TABLE" "$PANES"' EXIT

# pid ppid comm — every shape seen in the wild
cat > "$TABLE" <<'PS'
100 1 /bin/zsh
101 100 /Users/u/.local/bin/claude
200 1 /bin/zsh
300 1 /bin/zsh
301 300 /opt/homebrew/.../Python
302 301 claude
400 1 /bin/zsh
401 400 zsh
402 401 /Users/u/.local/share/claude/versions/2.1.232
500 1 /bin/zsh
501 500 nvim
600 1 /bin/zsh
601 600 claude-color
PS

cat > "$PANES" <<'P'
%1 100
%2 200
%3 300
%4 400
%5 500
%6 600
P

got=$(panes_with_session "$PANES" "$TABLE" | tr '\n' ' ')
want="%1 yes %2 no %3 yes %4 yes %5 no %6 no "
[ "$got" = "$want" ] && echo "ok   process tree verdicts" || { echo "FAIL got: $got"; echo "     want: $want"; }

# Each case named, so a failure says which shape broke.
check() { local p="$1" label="$2" want="$3" got
    got=$(panes_with_session "$PANES" "$TABLE" | awk -v p="$p" '$1==p {print $2}')
    [ "$got" = "$want" ] && echo "ok   $label -> $got" || echo "FAIL $label -> $got (want $want)"; }
check "%1" "session as a direct child" yes
check "%2" "bare shell" no
check "%3" "session under a pty wrapper" yes
check "%4" "session two shells deep, versioned binary" yes
check "%5" "editor, not a session" no
check "%6" "wrapper alone without its child" no
