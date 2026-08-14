#!/bin/bash
# The classifier fed the exact lines Claude draws, so a shape change is caught
# here rather than by a wrong glyph on a tab.
classify() {
    local tail="$1" want="input"
    case "$tail" in
        *"esc to interrupt"*|*"ctrl+b to run in background"*) want="running" ;;
    esac
    if [ "$want" = "input" ] && echo "$tail" | grep -qE "…[[:space:]]*\(|↓ [0-9.]+k? tokens"; then
        want="running"
    fi
    case "$tail" in
        *"Do you want "*|*"❯ 1. Yes"*) want="permission" ;;
    esac
    printf '%s' "$want"
}
t() { got=$(classify "$2"); [ "$got" = "$3" ] && echo "ok   $1 -> $got" || echo "FAIL $1 -> $got (want $3)"; }

t "stop-hook run"     "✻ Manifesting… (running stop hook · 39s · ↓ 710 tokens)" running
t "plain run"         "⏵ Herding… (5m 16s • ↓ 9.0k tokens)"                     running
t "interrupt hint"    "✻ Baking… (12s · esc to interrupt)"                      running
t "backgroundable"    "  $ git push origin main (ctrl+b to run in background)"  running
t "finished turn"     "✻ Sautéed for 13s"                                       input
t "idle prompt"       "❯ ␣  -- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle)"  input
t "permission"        " Do you want to create redifit.sh? ❯ 1. Yes"             permission
t "permission in run" "✻ Working… (3s) Do you want to proceed?"                 permission
