# tmux-claude-status

Every Claude Code session's state, live in your tmux tab bar — a spinner while it works, amber when it asks, red when it's blocked on an approval, green when it's done.

[![tests](https://github.com/LiveNL/tmux-claude-status/actions/workflows/tests.yml/badge.svg)](https://github.com/LiveNL/tmux-claude-status/actions/workflows/tests.yml)

![Demo: Claude state cycling through running → permission → input → done across four tmux windows](screenshots/demo.gif)

Run five Claude sessions in five windows and you spend your day guessing which tab wants you. This makes the bar answer it at a glance:

| State | Glyph | Color | When |
|-------|-------|-------|------|
| running | `⬢` *(animates)* | cyan | Claude is working |
| input | `?` | amber | Claude is waiting on your reply |
| permission | `!` | red | Claude needs approval to run a command |
| done | `✓` | green | Claude finished without a question |
| *(idle)* | — | dim | No active Claude session |

**No polling. No cron. No daemons.** [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) fire at each lifecycle event; the tab is repainted at that exact moment. Questions latch, finished turns hold their colour, and the transitions Claude never reports — Esc, a granted permission, a stop hook resuming the turn — are caught by watchers. Subagents can't repaint a tab that's waiting on you. The whole state machine is pinned by 260+ assertions run in CI, including a payload contract checked against captured real Claude payloads.

Curious why the tab never lies? Read [how it works](docs/how-it-works.md).

## Install

```bash
git clone https://github.com/LiveNL/tmux-claude-status
cd tmux-claude-status
bash install.sh
```

The installer copies the hook scripts to `~/.claude/hooks/` and merges their wiring into `~/.claude/settings.json` (backs up first, preserves existing hooks).

Requires [tmux](https://github.com/tmux/tmux) ≥ 3.0, [jq](https://stedolan.github.io/jq/), and the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI.

Then add **one** of these to `~/.tmux.conf` and reload:

- **Drop-in:** `source-file /path/to/tmux-claude-status/tmux/claude-state.conf`
- **Your own theme:** prepend the `#{?...}` fragment from `tmux/claude-state-prefix.txt` to your existing `window-status-format` and `window-status-current-format`.

## Desktop notifications (macOS)

![Permission notification](screenshots/notification-permission.png)
![Input notification](screenshots/notification-input.png)

Built in via `osascript` — nothing extra to install. With [`alerter`](https://github.com/vjeantet/alerter) (`brew install vjeantet/tap/alerter`) notifications become **clickable**: one click focuses your terminal and jumps to the window where Claude is waiting. Other platforms skip notifications silently.

## Customization

- **Colors:** edit `tmux/claude-state.conf`, swap `cyan`/`yellow`/`red`/`green` for your theme's values.
- **Spinner:** edit the `frames=(⬢ ⬡)` array in `hooks/lib/state.sh`.
- **No notifications:** set `CAN_NOTIFY="0"` in `hooks/notify.sh`.

More — pane seeding, debugging, tests, the demo GIF — in [docs/how-it-works.md](docs/how-it-works.md).

## Uninstall

```bash
rm -r ~/.claude/hooks/busy-window.sh ~/.claude/hooks/continue-window.sh \
      ~/.claude/hooks/notify.sh ~/.claude/hooks/permission-window.sh \
      ~/.claude/hooks/reset-window.sh ~/.claude/hooks/end-window.sh \
      ~/.claude/hooks/seed-panes.sh ~/.claude/hooks/lib
```

Then remove the `hooks` block from `~/.claude/settings.json` and the `source-file` line from `~/.tmux.conf`.
