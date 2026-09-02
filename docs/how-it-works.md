# How it works

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

## Attention outranks activity

Within one pane, two things outrank "running", because the tab is about where your attention is owed rather than about what a CPU is doing:

- **An unanswered question holds the tab amber** until you answer it, type something else, or the turn ends. Subagents and background commands fire tool events against the same pane, and each of those used to repaint a question you had not read yet.
- **A finished turn holds the colour it ended on.** Agents outlive the turn that spawned them — `← 3 agents` under an empty prompt — and their tool calls must not turn a tab you are meant to read back into a busy one. Only the main thread releases it: a prompt you type, an answer you give, or the turn resuming.

That last one is real: `Stop` fires *before* the stop-hook chain runs, and a hook can hand the turn straight back. So a Stop's colour is provisional — a watcher reads the transcript, and a main-thread message written after the Stop turns the tab back to running. Sidechain lines (the subagents) are ignored.

## The silent transitions

Pressing Esc fires no hook event of any kind — measured: an interrupt at 14:23:08 left nothing in the log, and the tab spun on over a run that had already stopped. The spinner is the only thing still awake at that point, so it watches the transcript it was handed and hands the tab back to you when the interrupt lands there.

Permission is the mirror image: nothing reports that you granted one. Claude fires no event on approval and `PostToolUse` only arrives when the command finishes, so a watcher releases the red as soon as either the command shows up under the session process or any hook fires against the pane — while ignoring the marks a *second*, queued dialog makes.

Not every event can be taken at face value either. Claude sends the same "waiting for your input" notification whether it is genuinely blocked on you or merely slow, so `notify.sh` weighs it against what the pane was last seen doing: a run mid-tool keeps spinning, and only a pending question tool or five silent minutes retires it. Permission requests always win.

## Certainty about panes

A hook may only touch a tab when it can name its pane with certainty, and `TMUX_PANE` is that certainty — the session inherited it from the pane it runs in. Hooks that arrive without it are dropped rather than attributed by inference: background and forked sessions run under the `claude --bg-pty-host` daemon, whose process tree never touches tmux, and they fire the same events as any session. Letting those reach a pane meant an agent could drive a tab it does not own.

That leaves two gaps hooks cannot fill, both answered from the process table rather than by guessing. `hooks/seed-panes.sh` gives an indicator to any pane whose process tree holds a live Claude session but has no state yet — a session that has not fired an event since it started is waiting on you — and clears panes whose session has exited. It never overrules a state a hook has set. Run it from tmux on a timer plus the events where a pane gains or loses a session; `--dry-run` reports without writing.

`hooks/link-pane.sh <session-id>` binds a pane to a conversation by hand, for the case below; `--guess` lists the conversations of that pane's project, `--clear` undoes it. Anything that conversation forks is then followed to the same tab.

One case cannot be linked from outside. A conversation started with no arguments can end up hosted inside Claude's daemon, with the pane holding only a client attached to it; the session id then appears in no process argument, environment or open file that a pane can be matched against. `seed-panes.sh` names those panes as `unlinked` — their tab still shows that a session is present, but it cannot follow what that session is doing. Starting the conversation in the pane (as `claude --resume <id>` does) is what makes its hooks carry the pane.

## The verifier

Hooks paint first, but some windows contain no event at all: a stop-hook chain (measured: 32 seconds of transcript silence), a continuation resumed by a stop hook, subagents working under a finished turn, an Esc that fires nothing. Rather than one watcher per gap, `hooks/reconcile-panes.sh` verifies every tab a few seconds apart against Claude Code's own account: `~/.claude/sessions/<pid>.json`, which the CLI maintains per live session with a `status` of `busy` | `waiting` | `idle` and the tmux pane it runs in.

Measured over an 11-hour working day before building it: tabs wore a finished colour for 35 minutes total while the session file said `busy` (one stretch of 203 seconds), and `waiting` coincided with an open permission dialog to within seconds. The division of labour stays: hooks are fast (~0.5s) and carry the meaning Claude does not track — a question and a finished turn are both `idle` to Claude — so the verifier only corrects drift: `busy` over a settled tab returns it to running, `waiting` paints permission, `idle` under a spinning tab retires it to input. Fresh edges on either side get a grace period, and an unanswered question outranks `busy`.

The session file is internal and undocumented, so `tests/test-session-contract.sh` pins the four fields the verifier reads — a Claude release that changes the shape fails the suite instead of silently ending verification. The verifier rides inside `seed-panes.sh --watch`'s loop; no extra daemon.

## The spinner

The animated spinner is a lightweight background process that writes a new frame to `@claude-spinner` twice a second and exits the moment the pane leaves `running`. One spinner per pane is guaranteed by an atomic lock directory; it gives up after four hours and clears the state, so a crashed session can't strand a half-lit glyph on the tab.

## Tests

`bash tests/run-all.sh` runs each suite against its own throwaway tmux server; CI runs them all on every push. Three of them are the safety net for changing any of this:

| Suite | Asserts |
|---|---|
| `test-interactions.sh` | every way a chat can move — turn, question, plan, permission, notification, subagent, continuation, session end — ends on the right state *and* draws the right glyph |
| `test-render.sh` | each state's glyph, colour and weight in the shipped format, the prefix fragment, and your own `~/.tmux.conf` if it uses `@claude-state` |
| `test-animation.sh` | the spinner runs only for `running`/`permission`, advances, stops on its own, and can never exist twice |
| `test-payload-contract.sh` | the payload fields the hooks read are present in payloads Claude really sent |

The last one closes the gap the others cannot: every suite feeds these hooks JSON written by hand, which would keep using a field name after Claude renamed it and stay green while the tab quietly stopped working. `hooks/capture-payloads.sh on` records one real payload per event into `tests/fixtures/` — redacted to key names, since a live payload carries the command that ran and the reply that was written — and `hooks/payload-contract.txt` says which fields must be in each. Recapture after a Claude upgrade; the suite says which version the fixtures came from.

## Debugging

Set `DEBUG_CLAUDE_HOOKS=1` to log hook decisions to `/tmp/claude-notify.log`. Separately, `touch /tmp/claude-hook-env.log` makes every hook record the pane and ancestry it was fired with — that is how sessions firing without a pane were found. Delete the file to switch it off.

## Demo assets

All README visuals are generated with [vhs](https://github.com/charmbracelet/vhs) plus a Python post-pass; `demo/drive.sh` stages a tmux server and drives the states the way live hooks would, styled by `demo/theme.conf`:

```bash
python3 demo/cover.py                              # screenshots/cover.png (drawn, no recording)
vhs demo/minis.tape && python3 demo/minis.py       # screenshots/state-*.gif (per-state clips)
vhs demo/demo.tape  && python3 demo/captions.py    # screenshots/demo.gif (workflow, captioned)
```

`minis.py` cuts the four state clips on the idle gaps the driver leaves between them, and `captions.py` calibrates its caption timing off the first permission-red frame — neither trusts a clock.
