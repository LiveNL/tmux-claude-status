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

![idle](screenshots/state-idle.png)
![running](screenshots/state-running.png)
![permission](screenshots/state-permission.png)
![input](screenshots/state-input.png)
![done](screenshots/state-done.png)

On macOS you also get desktop notifications:

![Permission notification](screenshots/notification-permission.png)
![Input notification](screenshots/notification-input.png)

**No polling. No cron. No background daemons.** State changes are triggered by [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) at the exact moment each lifecycle event fires.

## Why it stays truthful

The tab tracks where your attention is owed, not what a CPU happens to be doing — and those differ more often than you'd think:

- **Subagents don't repaint your tab.** An unanswered question holds amber and a finished turn holds its color, even while background agents keep firing tool events against the same pane.
- **Silent transitions are caught.** Pressing Esc fires no hook; neither does granting a permission; and a stop hook can hand a "finished" turn straight back. Each has a watcher, so the tab follows what actually happened.
- **A pane is only ever painted with certainty.** Hooks that can't name their pane are dropped rather than guessed — a daemon-hosted agent can never drive a tab it doesn't own.

The whole state machine is pinned by 260+ assertions across 18 suites, including a payload contract checked against fixtures captured from real Claude sessions — a Claude release that renames an event or a field shows up as a failing test, not as a tab that quietly stops telling the truth.

## Install

```bash
git clone https://github.com/LiveNL/tmux-claude-status
cd tmux-claude-status
bash install.sh
```

The installer:
- Copies hook scripts to `~/.claude/hooks/`
- Merges the hook configuration into `~/.claude/settings.json` (backs up first, preserves existing hooks)
- Guides you through the single tmux config line

### Requirements

- [tmux](https://github.com/tmux/tmux) ≥ 3.0
- [jq](https://stedolan.github.io/jq/)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI

macOS notifications use `osascript` — no extra packages needed. Install [`alerter`](https://github.com/vjeantet/alerter) to make notifications **clickable**: clicking one focuses your terminal and switches directly to the tmux window where Claude is running.

```bash
brew install vjeantet/tap/alerter
```

On other platforms notifications are silently skipped.

## tmux setup

Add **one** of these to `~/.tmux.conf`, then reload:

```bash
tmux source-file ~/.tmux.conf
```

**Option A — drop-in** (replaces `window-status-format` with a clean minimal style):

```tmux
source-file /path/to/tmux-claude-status/tmux/claude-state.conf
```

**Option B — embed in your existing theme** (keeps your current format, prepends the indicator):

Copy the `#{?...}` fragment from `tmux/claude-state-prefix.txt` to the start of your existing `window-status-format` and `window-status-current-format` strings.

## How it works

Claude Code fires hook scripts at exact lifecycle transitions. Each script records the state on its own pane (`@claude-pane-state`) and then republishes the window-scoped `@claude-state` that the status-bar format reads — no polling, just tmux variable reads on each status-bar refresh.

```
UserPromptSubmit / PreToolUse / PostToolUse  →  busy-window.sh       →  state = "running"  + spinner loop starts
PreCompact / PostCompact                     →  busy-window.sh       →  state = "running"  (compacting is work)
PermissionRequest                            →  permission-window.sh →  state = "permission"
Stop / Notification                          →  notify.sh            →  state = "input" | "done"
SessionStart                                 →  reset-window.sh      →  state = "input"    + spinner loop stops
SessionEnd                                   →  end-window.sh        →  state = ""         (nothing is running)
```

`hooks/events.txt` is the full contract, `SubagentStop` and its "deliberately unhandled" included; `tests/test-hook-coverage.sh` fails if it drifts from `install.sh` or from the events a Claude release actually emits.

The window shows the highest-priority state of any pane in it — `permission` > `running` > `input` > `done` > idle. Split a window between two Claude sessions and neither can overwrite the other's indicator; close one and its state leaves with its pane.

Within one pane, two things outrank "running", because the tab is about where your attention is owed rather than about what a CPU is doing:

- **An unanswered question holds the tab amber** until you answer it, type something else, or the turn ends. Subagents and background commands fire tool events against the same pane, and each of those used to repaint a question you had not read yet.
- **A finished turn holds the colour it ended on.** Agents outlive the turn that spawned them — `← 3 agents` under an empty prompt — and their tool calls must not turn a tab you are meant to read back into a busy one. Only the main thread releases it: a prompt you type, an answer you give, or the turn resuming.

That last one is real: `Stop` fires *before* the stop-hook chain runs, and a hook can hand the turn straight back. So a Stop's colour is provisional — a watcher reads the transcript, and a main-thread message written after the Stop turns the tab back to running. Sidechain lines (the subagents) are ignored.

Pressing Esc is the other silent transition — measured: an interrupt at 14:23:08 left no hook event of any kind, and the tab spun on over a run that had already stopped. The spinner is the only thing still awake at that point, so it watches the transcript it was handed and hands the tab back to you when the interrupt lands there.

Permission is the mirror image: nothing reports that you granted one. Claude fires no event on approval and `PostToolUse` only arrives when the command finishes, so a watcher releases the red as soon as either the command shows up under the session process or any hook fires against the pane — while ignoring the marks a *second*, queued dialog makes.

Not every event can be taken at face value. Claude sends the same "waiting for your input" notification whether it is genuinely blocked on you or merely slow, so `notify.sh` weighs it against what the pane was last seen doing: a run mid-tool keeps spinning, and only a pending question tool or five silent minutes retires it. Permission requests always win.

A hook may only touch a tab when it can name its pane with certainty, and `TMUX_PANE` is that certainty — the session inherited it from the pane it runs in. Hooks that arrive without it are dropped rather than attributed by inference: background and forked sessions run under the `claude --bg-pty-host` daemon, whose process tree never touches tmux, and they fire the same events as any session. Letting those reach a pane meant an agent could drive a tab it does not own.

That leaves two gaps hooks cannot fill, both answered from the process table rather than by guessing. `hooks/seed-panes.sh` gives an indicator to any pane whose process tree holds a live Claude session but has no state yet — a session that has not fired an event since it started is waiting on you — and clears panes whose session has exited. It never overrules a state a hook has set. Run it from tmux on a timer plus the events where a pane gains or loses a session; `--dry-run` reports without writing.

`hooks/link-pane.sh <session-id>` binds a pane to a conversation by hand, for the case below; `--guess` lists the conversations of that pane's project, `--clear` undoes it. Anything that conversation forks is then followed to the same tab.

One case cannot be linked from outside. A conversation started with no arguments can end up hosted inside Claude's daemon, with the pane holding only a client attached to it; the session id then appears in no process argument, environment or open file that a pane can be matched against. `seed-panes.sh` names those panes as `unlinked` — their tab still shows that a session is present, but it cannot follow what that session is doing. Starting the conversation in the pane (as `claude --resume <id>` does) is what makes its hooks carry the pane.

The animated spinner is a lightweight background process that writes a new frame to `@claude-spinner` twice a second and exits the moment the pane leaves `running`. One spinner per pane is guaranteed by an atomic lock directory; it gives up after four hours and clears the state, so a crashed session can't strand a half-lit glyph on the tab.

## Customization

**Colors:** Edit `tmux/claude-state.conf` and replace the named colors (`cyan`, `yellow`, `red`, `green`) with your theme's values (e.g. `colour14`, `#fabd2f`).

**Spinner frames:** Edit the `frames=(⬢ ⬡)` array in `hooks/lib/state.sh` — any Unicode glyphs work.

**Clickable notifications:** Install `alerter` (`brew install vjeantet/tap/alerter`). When present, clicking a notification focuses your terminal and switches to the right tmux window automatically.

**Desktop notifications:** Set `CAN_NOTIFY="0"` near the top of `hooks/notify.sh` to disable, or swap `notify_macos` for `notify-send`/`paplay` for Linux.

**Debug logging:** Set `DEBUG_CLAUDE_HOOKS=1` to log hook decisions to `/tmp/claude-notify.log`. Separately, `touch /tmp/claude-hook-env.log` makes every hook record the pane and ancestry it was fired with — that is how sessions firing without a pane were found. Delete the file to switch it off.

**Tests:** `bash tests/run-all.sh` runs each suite against its own throwaway tmux server; CI runs them all on every push. Three of them are the safety net for changing any of this:

| Suite | Asserts |
|---|---|
| `test-interactions.sh` | every way a chat can move — turn, question, plan, permission, notification, subagent, continuation, session end — ends on the right state *and* draws the right glyph |
| `test-render.sh` | each state's glyph, colour and weight in the shipped format, the prefix fragment, and your own `~/.tmux.conf` if it uses `@claude-state` |
| `test-animation.sh` | the spinner runs only for `running`/`permission`, advances, stops on its own, and can never exist twice |
| `test-payload-contract.sh` | the payload fields the hooks read are present in payloads Claude really sent |

The last one closes the gap the others cannot: every suite feeds these hooks JSON written by hand, which would keep using a field name after Claude renamed it and stay green while the tab quietly stopped working. `hooks/capture-payloads.sh on` records one real payload per event into `tests/fixtures/` — redacted to key names, since a live payload carries the command that ran and the reply that was written — and `hooks/payload-contract.txt` says which fields must be in each. Recapture after a Claude upgrade; the suite says which version the fixtures came from.

**Demo GIF:** `screenshots/demo.gif` is recorded with [vhs](https://github.com/charmbracelet/vhs) — `vhs demo/demo.tape` re-renders it; `demo/drive.sh` stages a tmux server and drives the states the way live hooks would.

## Uninstall

```bash
rm -r ~/.claude/hooks/busy-window.sh \
      ~/.claude/hooks/continue-window.sh \
      ~/.claude/hooks/notify.sh \
      ~/.claude/hooks/permission-window.sh \
      ~/.claude/hooks/reset-window.sh \
      ~/.claude/hooks/end-window.sh \
      ~/.claude/hooks/seed-panes.sh \
      ~/.claude/hooks/lib
```

Then remove the `hooks` block from `~/.claude/settings.json` and the `source-file` line from `~/.tmux.conf`.
