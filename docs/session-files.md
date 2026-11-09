# Session files

Meerkat.app knows nothing about Claude Code. It watches a directory of small
JSON files, one per session, and draws whatever they say. The Claude Code hook
(`hooks/meerkat-hook.py`) is just one writer of those files. Anything else that
writes them in this format gets rows in the window, the sounds and the paw's
colour: an adapter for another coding agent, a build script, a test runner.

To port Meerkat to another coding agent, start with
[other-agents.md](other-agents.md).

This page is the contract between a writer and the app. It describes version 1,
as written by `meerkat-hook.py` and read by `Session(json:)` in
`Sources/Models.swift` and `SessionStore.reload()` in `Sources/SessionStore.swift`.

## Where the files live

```
~/.meerkat/sessions/<session_id>.json
```

`$MEERKAT_HOME` replaces `~/.meerkat` for both the hook and the app.

The app reads every file in `sessions/` whose name ends in `.json`. The file
name is not parsed: the session's identity is the `session_id` field inside.
Name the file after the id anyway, keeping only letters, digits, `-` and `_`,
so that one session always lands in one file.

Other files in `~/.meerkat` (`usage.json`, `usage-api.json`, `dismissed.json`)
belong to the app and the Claude Code status line. A writer leaves them alone.

## An example

```json
{
  "version": 1,
  "session_id": "4f1c2a9e-0b7d-4e55-9a51-7c2f0e6d8b13",
  "updated": 1794188212.48,
  "cwd": "/Users/me/src/api-server",
  "label": "api-server",
  "since": 1794188090.11,
  "state": "working",
  "detail": "Wire up the progress bar",
  "waiting_for": "",
  "tasks_total": 5,
  "tasks_done": 3,
  "turns": 2,
  "model": "claude-opus-5-5"
}
```

## Fields

Times are seconds since 1970 (Unix time) as JSON numbers; a fraction is fine.
Counts are JSON integers.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `session_id` | string | **yes** | Stable, unique id. A file without it, or with it empty, is skipped. |
| `state` | string | no | One of the five states below. Anything else, or missing, reads as `idle`. |
| `since` | number | no | When the current state began. Drives the elapsed clock, the sort order and the sounds. Defaults to 0 (1970), so always set it. |
| `updated` | number | no | When the writer last touched the file. Decides when a row goes away (see below). Defaults to `since`. |
| `label` | string | no | The row's name. The hook uses the session title, else the folder's name, at most 40 characters. Defaults to `session`. |
| `cwd` | string | no | Working folder, shown when you hover the row. |
| `detail` | string | no | One line of what the session is doing: the hook puts your latest prompt here, at most 110 characters. |
| `waiting_for` | string | no | Why it needs you, or why it failed. Shown instead of `detail` while the state is `attention` or `failed`; when empty, `detail` shows. Keep it short: "needs permission". |
| `tasks_total` | integer | no | Size of the task list. When above 0, the row gets a progress bar, and while working an `n/m` count beside the time. |
| `tasks_done` | integer | no | Tasks finished. The bar is clamped to 0–100%. |
| `turns` | integer | no | How many messages you have sent the session. Shown on hover, and part of what brings back a dismissed row. |
| `version` | integer | no | `1`. Written for future readers; the app does not check it yet. |
| `model` | string | no | Written by the hook; not read by the app. |

The app ignores fields it does not know, so a writer may add its own.

Types are read strictly. A string where a number belongs (`"since": "1794188090"`)
or a fraction where an integer belongs (`"tasks_done": 2.5`) is treated as
missing, not converted.

### States

| `state` | Dot | Beside the time | Second line | Header critter |
|---|---|---|---|---|
| `working` | amber, breathing | `n/m` if it has tasks | `detail` | stands tall and scans |
| `attention` | orange, breathing | `needs you` | `waiting_for` | bobs with a `!` |
| `done` | green tick | `done` | `detail` | throws its arms up |
| `failed` | red | `failed` | `waiting_for` | slumps |
| `idle` | grey | | `detail` | dozes |

The second line falls back to `detail` when `waiting_for` is empty, and to the
state's own word when both are. The time is how long since `since`.

Rows sort by urgency (`attention` > `failed` > `working` > `done` > `idle`),
then newest `since` first. The header critter wears the most urgent state on the
list.

## What the app does with it

**Sounds.** The app compares each session against how it last saw it:

- a state change into `done` chimes;
- a state change into `attention` or `failed` pings;
- `attention` staying `attention` with a new `since` pings again. So restamp
  `since` for each new request for permission or input, even on top of one
  already waiting, and leave it alone when nothing new has happened.

A session seen for the first time makes no sound, so a file that is already
`done` when Meerkat starts stays quiet.

**When rows go away.** Measured from `updated`:

| State | Hidden after |
|---|---|
| `done` | 15 minutes |
| `idle` | 30 minutes |
| any | 12 hours |

`working`, `attention` and `failed` stay until the 12-hour limit, so a writer
whose session is still going should touch `updated` now and then. Deleting the
file removes the row at once: do that when the session ends.

**Dismissed rows.** You can dismiss a row. It stays hidden while `state`,
`since` and `turns` all stay the same, and comes back when any of them changes.
Events that are not news (a heartbeat, a task ticking over) should therefore
update `updated` and the task counts only.

## Writing the files safely

1. **Write a temporary file in the same directory, then rename it over the
   real one.** The app re-reads the directory the moment an entry is created,
   renamed or removed, but it does not see a file being rewritten in place; such
   a write only shows up on its 3-second backstop. A rename also means the app
   never reads half a file. The temporary name must not end in `.json`: the hook
   uses `<id>.json.tmp.<pid>`.
2. **Serialise read-modify-write per session** if events can arrive at once.
   The hook takes `<id>.json.lock` with an exclusive create and gives up after
   0.75 seconds rather than stall the agent.
3. **Delete the file when the session ends.**
4. **Mind the agent you run inside.** If your writer is a hook, it sits in the
   agent's critical path: keep it to a quick file write, never crash it, and
   check what the agent does with your stdout and exit code. The Claude Code
   hook prints nothing and always exits 0, for the reasons in the README.

Stale files are swept for you: on every Claude Code `SessionStart`, the hook
deletes any `.json` in `sessions/` untouched for 24 hours, whoever wrote it.

### Avoid id collisions

Ids from different tools share one directory. Prefix yours with the tool's name
(`codex-…`, `ci-…`) so they cannot collide with each other or with Claude
Code's UUIDs.

## A minimal writer

A shell script that shows a long build as a row, then rings when it is done:

```bash
#!/bin/sh
dir="${MEERKAT_HOME:-$HOME/.meerkat}/sessions"
id="build-$$"
mkdir -p "$dir"

put() { # state, detail
  now=$(date +%s)
  printf '{"version":1,"session_id":"%s","label":"build","cwd":"%s","state":"%s","detail":"%s","since":%s,"updated":%s}' \
    "$id" "$PWD" "$1" "$2" "$now" "$now" > "$dir/$id.json.tmp"
  mv "$dir/$id.json.tmp" "$dir/$id.json"
}

put working "make release"
if make release; then put done "make release"; else put failed "make release"; fi
```

(`printf` does no JSON escaping, so this only holds up while the folder path
and the detail have no `"` or `\` in them. Anything taken from outside, such as
a commit message, wants a real JSON encoder.)

The hook's `apply()` function is the reference for turning a stream of agent
events into these fields; it is short and commented.
