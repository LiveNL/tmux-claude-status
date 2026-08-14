#!/bin/bash
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DEST="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
R='\033[0m'

ok()   { echo -e "  ${GREEN}✓${R}  $*"; }
info() { echo -e "  ${YELLOW}→${R}  $*"; }
bold() { echo -e "${BOLD}$*${R}"; }

# ── Preflight ──────────────────────────────────────────────────────────────

bold "\nclaude-tmux-hooks installer"
echo ""

for dep in tmux jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "Error: '$dep' is required but not installed." >&2
        exit 1
    fi
done

# ── Step 1: Install hooks ──────────────────────────────────────────────────

bold "1. Installing hooks"
mkdir -p "$HOOKS_DEST"

for hook in busy-window.sh continue-window.sh notify.sh permission-window.sh reset-window.sh; do
    cp "$SCRIPT_DIR/hooks/$hook" "$HOOKS_DEST/$hook"
    chmod +x "$HOOKS_DEST/$hook"
    ok "Installed $HOOKS_DEST/$hook"
done

# Shared state helpers — every hook sources this from its own directory.
mkdir -p "$HOOKS_DEST/lib"
cp "$SCRIPT_DIR/hooks/lib/state.sh" "$HOOKS_DEST/lib/state.sh"
ok "Installed $HOOKS_DEST/lib/state.sh"

# Seeder — not wired to an event; run from tmux at startup or by hand.
cp "$SCRIPT_DIR/hooks/seed-panes.sh" "$HOOKS_DEST/seed-panes.sh"
chmod +x "$HOOKS_DEST/seed-panes.sh"
ok "Installed $HOOKS_DEST/seed-panes.sh"

# ── Step 2: Merge settings.json ────────────────────────────────────────────

bold "\n2. Configuring Claude Code settings"

HOOKS_FRAGMENT=$(jq -n \
    --arg reset      "bash $HOOKS_DEST/reset-window.sh" \
    --arg notify     "bash $HOOKS_DEST/notify.sh" \
    --arg busy       "bash $HOOKS_DEST/busy-window.sh" \
    --arg continue   "bash $HOOKS_DEST/continue-window.sh" \
    --arg permission "bash $HOOKS_DEST/permission-window.sh" \
    '{
      hooks: {
        SessionStart:      [{"matcher": "", hooks: [{"type": "command", command: $reset}]}],
        Notification:      [{"matcher": "", hooks: [{"type": "command", command: $notify}]}],
        Stop:              [{"matcher": "", hooks: [{"type": "command", command: $notify}]}],
        PreToolUse:        [{"matcher": "", hooks: [{"type": "command", command: $busy}]}],
        PostToolUse:       [{"matcher": "", hooks: [{"type": "command", command: $continue}]}],
        UserPromptSubmit:  [{"matcher": "", hooks: [{"type": "command", command: $busy}]}],
        PermissionRequest: [{"matcher": "", hooks: [{"type": "command", command: $permission}]}]
      }
    }')

if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    echo "$HOOKS_FRAGMENT" | jq '.' > "$SETTINGS"
    ok "Created $SETTINGS"
else
    BACKUP="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$BACKUP"
    info "Backed up existing settings to $(basename "$BACKUP")"

    # Additive merge: for each hook event, put our entries first then existing,
    # deduplicate by script filename so ~/... and /abs/path/... variants of the
    # same script are treated as the same entry (our absolute-path version wins).
    MERGED=$(jq \
        --argjson new "$HOOKS_FRAGMENT" '
        reduce ($new.hooks | keys[]) as $event (
            .;
            .hooks[$event] = (
                ($new.hooks[$event] + (.hooks[$event] // []))
                | unique_by(.hooks[0].command | split(" ") | last | split("/") | last)
            )
        )
        ' "$SETTINGS")

    echo "$MERGED" | jq '.' > "$SETTINGS"
    ok "Merged hooks into $SETTINGS"
fi

# ── Step 3: tmux instructions ──────────────────────────────────────────────

echo ""
bold "3. Configure tmux"

TMUX_CONF="${HOME}/.tmux.conf"
SPINNER_FORMAT='#{@claude-spinner}'

if [ -f "$TMUX_CONF" ] && grep -q '@claude-state' "$TMUX_CONF"; then
    if grep -q '@claude-spinner' "$TMUX_CONF"; then
        ok "tmux already configured"
    else
        tmp=$(mktemp)
        if grep -q 'spinner\.sh' "$TMUX_CONF"; then
            # Upgrade from spinner.sh to background loop format
            sed "s|#(bash[^)]*spinner\.sh)|${SPINNER_FORMAT}|g" "$TMUX_CONF" > "$tmp" \
                && mv "$tmp" "$TMUX_CONF"
        else
            # Fresh: replace static · glyph
            sed "s|]· |]${SPINNER_FORMAT} |g" "$TMUX_CONF" > "$tmp" \
                && mv "$tmp" "$TMUX_CONF"
        fi
        ok "Updated $TMUX_CONF with animated spinner"
        info "Reload tmux: tmux source-file $TMUX_CONF"
    fi
else
    cat << TMUX

  Add one of the following to your ~/.tmux.conf, then reload:
  tmux source-file ~/.tmux.conf

  ── Option A: Use the included standalone format ──────────────────────────
  Replaces your window-status-format with a clean minimal default.

    source-file $SCRIPT_DIR/tmux/claude-state.conf

  ── Option B: Embed in your existing format ───────────────────────────────
  Paste the prefix from tmux/claude-state-prefix.txt at the start of your
  existing window-status-format and window-status-current-format strings.

    cat $SCRIPT_DIR/tmux/claude-state-prefix.txt

TMUX
fi

bold "Done."
echo ""
