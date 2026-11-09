# Meerkat

English | [简体中文](README.zh-CN.md)

A small sentry for your Mac desktop. It watches your Claude Code sessions and
stands up the moment one finishes or needs you, so you can walk away from a long
task without keeping a window open to check on it.

```
   ╭──────────────────────────────────────────╮
   │   /\_/\    MEERKAT                       │
   │  ( o.o )   1 needs you · 1 working       │
   │   > ^ <                                  │
   ├──────────────────────────────────────────┤
   │ PLAN USAGE                      just now │
   │ Session  ▓▓░░░░░░░░░   16%      12:10 AM │
   │ Week     ▓▓▓▓▓▓▓▓▓░░   81%   Mon 9:00 AM │
   │ Fable    ▓▓▓▓▓▓▓▓▓▓▓  100%   Mon 9:00 AM │
   ├──────────────────────────────────────────┤
   │ ● api-server            needs you · 2m   │
   │   needs permission                       │
   ├──────────────────────────────────────────┤
   │ ● meerkat                    3/5 · 14m   │
   │   Wire up the progress bar               │
   │   ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░                   │
   ├──────────────────────────────────────────┤
   │ ✓ docs                       done · 6m   │
   │   Update the README                      │
   ╰──────────────────────────────────────────╯
```

The meerkat is drawn, not an emoji: it stands tall and scans while work is
running, bobs with a `!` over its head (and pings) when a session is blocked on
you, throws its arms up and chimes when one finishes, slumps when one fails, and
dozes when everything is quiet. Right-click → Mute sounds silences both sounds.

## What it shows, and what it can't

**Per session:** whether it is working, waiting on you, finished (a tick and
`done`) or failed; how long it has been in that state; the prompt it is working
on, or the one it finished; and a real progress bar whenever Claude is keeping a
task list.

**Plan usage: the same bars as claude.ai.** The current 5-hour session, the
week across all models, and every model with a weekly limit of its own (Fable,
say), each with its percentage and when it resets — the rows of Settings →
Usage on claude.ai, because they come from the same place. Verified Ultra
accounts have no 5-hour limit, so the session row stays away unless a window is
running.

That place is `api.anthropic.com/api/oauth/usage`, the endpoint behind Claude
Code's own `/usage` screen. It needs your Claude Code sign-in, so this is the
one part of Meerkat that touches a credential, and it does so narrowly:

- It reads the token the way Claude Code does, with `/usr/bin/security` from
  the `Claude Code-credentials` item in your login keychain, so macOS does not
  ask for permission. A locked keychain is noticed first and skipped, so
  Meerkat never raises an unlock dialog.
- The token is read fresh for each request, used for that one request, and
  never logged or written anywhere. `~/.meerkat/usage-api.json` records the
  figures and the outcome of each check, nothing else.
- Meerkat never refreshes the token. A refresh rotates it, which would sign
  Claude Code out; an expired token just waits for Claude Code to renew it.
- It looks every 3 minutes, soon after a session finishes a turn, and on wake.
- Right-click → **Turn off plan usage** hides the bars at once and stops every
  keychain read and request until you turn it back on.

This works whichever Claude surface you use — terminal, VS Code or the desktop
app. If the endpoint cannot be reached, Meerkat falls back to figures from a
terminal status line (`scripts/enable-usage.sh`), which carry the 5-hour and
weekly bars but not the per-model ones.

## Only Claude Code

Meerkat watches Claude Code and nothing else. Using Codex, Cursor or another
agent? The window does not depend on Claude Code, only the hook that feeds it
does, so a fork is a small job your own coding agent can do:
[docs/other-agents.md](docs/other-agents.md) explains what to change and gives
a prompt to start it with.

## Requirements

- macOS 13 or later
- The Xcode command line tools, for `swiftc` and `python3`:
  `xcode-select --install` (one download, no full Xcode needed)

## Install

```bash
./install.sh                    # wire the hook into Claude Code
./build.sh                      # compile Meerkat.app
open build/Meerkat.app          # start it
```

Then **start a new Claude Code session** — an already-running session does not
pick up new hooks, though `/clear` in one will do it. Send it a prompt and a row
appears.

Works across the terminal CLI, the VS Code extension and the desktop app: all
three read the same `~/.claude/settings.json`, so one install covers them all.

Something not working? `./scripts/doctor.sh` checks every link in the chain and
tells you which command fixes what it finds.

## Using the window

| | |
|---|---|
| Move it | Drag anywhere that isn't a button |
| Shrink to just the meerkat | Click the meerkat |
| Hide it | ⌃⌘M from anywhere, or right-click → Hide Meerkat |
| Bring it back | ⌃⌘M from anywhere, click the paw in the menu bar, or open Meerkat again |
| Menu (mute, quit, …) | Right-click the window, or the paw |
| See the folder, the prompt (its first 110 characters) and counts | Hover a row |
| Dismiss a row you are done with | Hover it and click the × over its time. It comes back when that session has news: a message from you, a new request for permission or input, or a change of state |
| Bring dismissed rows back | Click "N dismissed" beside MEERKAT at the top, or right-click → Show dismissed sessions |

It floats above your other windows, follows you across Spaces, stays out of the
Dock and the app switcher, and remembers where you left it.

Hidden, it keeps watching. The sounds still play, and the paw in the menu bar
takes the colour of a session that needs you (orange) or has failed (red),
unless you have dismissed its row. Every launch starts with the window showing.

⌃⌘M toggles, so the same keys put it away again. While Meerkat runs it takes
⌃⌘M from other apps' own shortcuts. Another app's system-wide ⌃⌘M fires
alongside it, unless that app claimed the keys exclusively, which silences
Meerkat's. If either bites, change it in `Sources/HotKey.swift`. It is a key
position rather than a letter: on French AZERTY it is the comma key.

On a MacBook with a notch, a crowded menu bar hides whatever does not fit to the
right of the notch, and a new icon such as the paw is the first to go. If you
cannot see it, make room -- quit a menu bar app you can do without, or ⌘-drag a
system icon off the bar -- or simply use ⌃⌘M.

### Start it at login

```bash
cp -R build/Meerkat.app /Applications/
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Meerkat.app", hidden:true}'
```

## How it works

```
Claude Code ──hooks──▶ ~/.meerkat/meerkat-hook.py ──▶ ~/.meerkat/sessions/*.json
                                                              │
                                                       Meerkat.app
                                              (kernel watch + 3s backstop)
                                                              │
login keychain ──security──▶ token ──▶ GET api.anthropic.com/api/oauth/usage
                                        (every 3 min, after a turn, on wake)
```

The app itself knows nothing about Claude Code: it draws whatever the session
files say. [docs/session-files.md](docs/session-files.md) describes their
format.

Nine lifecycle events drive a small state machine, one JSON file per session:

| Event | What Meerkat does |
|---|---|
| `SessionStart` | A session appears, idle (a compaction mid-turn leaves it working) |
| `UserPromptSubmit` | It starts working; shows the prompt |
| `PostToolBatch` | Heartbeat, and clears "needs you" once the round you approved has run |
| `Notification` | It's blocked on a permission prompt or a question |
| `TaskCreated` / `TaskCompleted` | The progress bar |
| `Stop` | Finished — the bounce and the chime |
| `StopFailure` | The turn died on an API error |
| `SessionEnd` | Row disappears |

`PreToolUse` and `PostToolUse` are deliberately **not** used. They fire on every
single tool call, and a status widget is not worth a subprocess per tool call.
`PostToolBatch` fires once per round of tool calls, which is all the heartbeat
this needs.

The hook follows three rules, because it runs inside Claude Code's critical
path: it never writes to stdout (stdout from a `SessionStart` or
`UserPromptSubmit` hook is injected straight into Claude's context), it always
exits 0 (exit 2 on `Stop` would stop Claude from stopping), and it does nothing
slower than a small file write. `install.sh` registers it through one line of
`/bin/sh` that exits 0 if the script itself is missing, the one failure the
script cannot catch. `scripts/selftest.sh` drives the state machine through a
full lifecycle of synthetic events and checks the stdout and exit-code rules on
the inputs most likely to break them:

```bash
./scripts/selftest.sh            # the hook, over a full session lifecycle
./scripts/geometry_check.py      # the meerkat stays inside its canvas
./scripts/usage-parse-check.sh   # the plan-usage parsers, on canned replies
```

`geometry_check.py` mirrors the drawing arithmetic from `Critter.swift` in
Python and sweeps every mood through a full animation cycle. A `Canvas` clips
silently, so a shape a few units out of bounds is easy to write and hard to
notice — this catches it without having to look at the window. It is a model of
that file rather than a reader of it, so keep the two in step by hand.

## Known rough edges

- **Task counts are event-counted, not read.** If Claude deletes a task, or had
  a task list going before Meerkat was installed, the denominator can be off.
  It resets when a session starts fresh, is cleared or is forked (a resumed or
  compacted one keeps counting), and never shows a dishonest ratio like 4/3.
- **Cloud sessions won't appear.** They don't read your local settings file.
- **A hook needs workspace trust.** In a folder whose trust dialog you haven't
  accepted, no hooks run at all.
- **A crashed session can leave a stale row.** Anything not updated for 12 hours
  is hidden, and its file is deleted by the next `SessionStart` once it is 24
  hours old. Dismiss it to be rid of it sooner.
- **"Needs you" outlasts your answer.** After you approve a permission prompt
  the row keeps saying so until that round of tools finishes, because no hook
  fires in between. A long-running approved command shows as "needs you" for as
  long as it runs.
- **The usage endpoint is undocumented.** It is what Claude Code and claude.ai
  use, but nothing promises its shape. Meerkat parses it defensively: a row it
  cannot read is left out, never shown as a made-up number, and a failed check
  keeps the last figures up with their age in amber and the reason in the
  tooltip. A figure from before its window's reset shows as a dash until a
  fresh one arrives. `scripts/usage-parse-check.sh` holds the replies it
  understands.
- **Plan usage needs a Claude plan sign-in.** An API-key sign-in has no plan
  and so no plan usage. A Claude Code run with `CLAUDE_CONFIG_DIR` keeps its
  sign-in under a different keychain item, which Meerkat does not look for.
- **Instant updates depend on the hook renaming its files.** Watching a
  directory reports entries appearing and vanishing, not an existing file being
  rewritten in place, so `meerkat-hook.py` writes a temp file and renames it
  over the old one. Change that and updates quietly fall back to the 3-second
  poll.

## Uninstall

```bash
./scripts/enable-usage.sh --disable   # only if you set up the status line fallback
./install.sh --uninstall              # removes Meerkat's hooks from settings.json
```

Then quit Meerkat (right-click → Quit Meerkat), remove its login item and the
`/Applications` copy if you made them, and, optionally, `rm -rf ~/.meerkat`.
Quit it first: a running Meerkat recreates the folder.

`--uninstall` removes only Meerkat's own hook entries and leaves everything else
in `settings.json`, though the file is rewritten (re-indented). `install.sh`
backs `settings.json` up with a timestamp before any change, and `--dry-run`
prints the merged result without writing anything.

## Layout

```
hooks/meerkat-hook.py       the state machine (python3, no dependencies)
hooks/meerkat-statusline.py fallback usage harvester, run as a status line
Sources/main.swift          app startup
Sources/Models.swift        Session, Mood, and the plan-usage parsers
Sources/UsageFetcher.swift  fetches plan usage from claude.ai
Sources/SessionStore.swift  reads and watches the state files
Sources/Critter.swift       the meerkat, drawn in a 100x130 design space
Sources/ContentView.swift   the window content
Sources/PanelController.swift the floating panel
Sources/StatusItem.swift    the paw in the menu bar
Sources/HotKey.swift        the ⌃⌘M shortcut
install.sh                  merges hooks into ~/.claude/settings.json
build.sh                    swiftc -> build/Meerkat.app
scripts/doctor.sh           diagnoses a broken setup
scripts/check-usage.sh      shows the plan-usage figures Meerkat has, and from where
scripts/enable-usage.sh     installs the fallback status line harvester
scripts/selftest.sh         exercises the hook state machine
scripts/geometry_check.py   checks the drawing stays inside its canvas
scripts/usage-parse-check.sh checks the plan-usage parsers
scripts/usage_parse_check.swift  ... with these canned replies
scripts/demo.sh             fills the widget with fake sessions to look at
```
