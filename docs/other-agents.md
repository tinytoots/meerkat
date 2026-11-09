# Using Meerkat with another coding agent

Meerkat supports Claude Code, and only Claude Code. There are no plans to add
adapters for other agents here.

It is, however, built to be easy to port. The window knows nothing about Claude
Code: it draws whatever the session files in `~/.meerkat/sessions/` say. Only
the hook that writes those files, the installer that registers it, and the plan
usage bars are tied to Claude Code. If your agent can run a command on its own
lifecycle events (most can now: look for "hooks" in its docs), you can make your
own fork of Meerkat for it, and your coding agent can do most of the work.

## Hand this to your coding agent

Open a fork of this repository in your agent and give it something like:

> Port Meerkat to <your agent>. Read `docs/other-agents.md` and
> `docs/session-files.md` first, then `hooks/meerkat-hook.py` and `install.sh`.
> Keep the Swift app and the session-file format as they are. Write a hook for
> <your agent>'s lifecycle events that produces the same session files, make
> `install.sh` register it in <your agent>'s config, and update `doctor.sh`,
> `scripts/selftest.sh` and the README to match. Look up <your agent>'s hook
> documentation rather than guessing its event names and fields.

The rest of this page is what it needs to know.

## What to keep, change and drop

| Part | Files | In a port |
|---|---|---|
| The window, the critter, sounds, the menu bar paw | `Sources/` (all but `UsageFetcher.swift`), `build.sh` | Keep as is |
| The session-file format | [session-files.md](session-files.md) | Keep: it is the contract the app reads |
| The hook: agent events → session files | `hooks/meerkat-hook.py` | Rewrite `apply()` and `label_for()` for your agent's events. Keep the rest: atomic writes, the lock, the stale sweep, `tidy()` |
| Registering the hook | `install.sh`, `scripts/doctor.sh` | Rewrite for wherever your agent keeps its hook config |
| Tests | `scripts/selftest.sh` | Replace the synthetic Claude Code events with your agent's |
| Plan usage bars | `Sources/UsageFetcher.swift`, `hooks/meerkat-statusline.py`, `scripts/enable-usage.sh`, `scripts/check-usage.sh` | Claude-only. Drop them, or replace them with your agent's own limits if it exposes any |

Plan usage needs no code change to stay out of the way: with no Claude Code
sign-in in the keychain it finds nothing and the bars never appear.
Right-click → **Turn off plan usage** also stops it looking.

## Mapping your agent's events

This is what the Claude Code hook does with each event. Find the nearest
equivalent in your agent; the states and fields are described in
[session-files.md](session-files.md).

| Claude Code event | Meerkat does | Look for an event that… |
|---|---|---|
| `SessionStart` | create the file, state `idle`; reset counts on a fresh start or clear | fires when a session starts or resumes |
| `UserPromptSubmit` | state `working`, `detail` = the prompt, `turns` + 1 | fires when you send a message |
| `PostToolBatch` | state `working`, clear `waiting_for` (heartbeat; also ends "needs you" once you have approved) | fires after tools run. Prefer one per round over one per tool call |
| `Notification` | state `attention`, `waiting_for` = why, restamp `since` | fires when it asks for permission or input |
| `TaskCreated` / `TaskCompleted` | `tasks_total` / `tasks_done` + 1 | tracks a to-do or plan list (many agents have none: leave the counts at 0 and there is no bar) |
| `Stop` | state `done` | fires when a turn finishes |
| `StopFailure` | state `failed`, `waiting_for` = the error | fires when a turn dies on an error |
| `SessionEnd` | delete the file | fires when the session closes |

Two things matter most for it to feel right: a clear "needs you" when the agent
is blocked on you, and a `done` at the end of every turn. If your agent has no
event for one of these, the row still works, it just shows less.

## Rules for the hook

The hook runs inside your agent's critical path, so before writing it, find out
from your agent's docs:

- **What it does with the hook's stdout.** Some agents feed it into the model's
  context. The Claude Code hook prints nothing at all.
- **What exit codes mean.** In several agents, exit 2 blocks the action or keeps
  the agent from stopping. The Claude Code hook always exits 0, even when it
  crashes.
- **Whether hooks need approving** before they run (some agents ask you to
  review new hooks first), so the installer can say so.

And keep it fast: a few milliseconds of file writing, nothing more.

## Sharing a port

This repository stays Claude Code only, so a port lives in its own fork, which
you maintain. If you publish it, an issue here with a link helps the next
person looking for the same agent.
