#!/bin/bash
# Wires Meerkat's hook into Claude Code.
#
#   ./install.sh              install or update
#   ./install.sh --uninstall  remove
#   ./install.sh --dry-run    show the merged settings without writing
#
# This edits ~/.claude/settings.json, which is shared by the terminal CLI, the
# VS Code extension and the desktop app, so one install covers all three.
# Your existing settings are preserved and a timestamped backup is written
# before any change.

set -euo pipefail
cd "$(dirname "$0")"

HERE="$(pwd)"
MEERKAT_HOME="$HOME/.meerkat"
SETTINGS="$HOME/.claude/settings.json"
MODE="install"

for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE="uninstall" ;;
    --dry-run) MODE="dry-run" ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  cat >&2 <<'MSG'
python3 was not found, and the hook is a python3 script.

On macOS it arrives with the Xcode command line tools, which you also need to
build the app:

    xcode-select --install
MSG
  exit 1
fi

if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
  echo "python3 at $PY is too old; need 3.8 or newer." >&2
  exit 1
fi

if [ "$MODE" != "uninstall" ]; then
  mkdir -p "$MEERKAT_HOME/sessions"
  install -m 0755 "$HERE/hooks/meerkat-hook.py" "$MEERKAT_HOME/meerkat-hook.py"
  echo "hook   -> $MEERKAT_HOME/meerkat-hook.py"
fi

mkdir -p "$(dirname "$SETTINGS")"

MEERKAT_MODE="$MODE" \
MEERKAT_PY="$PY" \
MEERKAT_HOOK="$MEERKAT_HOME/meerkat-hook.py" \
MEERKAT_SETTINGS="$SETTINGS" \
"$PY" - <<'PYEOF'
import json
import os
import shutil
import sys
import time

mode = os.environ["MEERKAT_MODE"]
python = os.environ["MEERKAT_PY"]
hook = os.environ["MEERKAT_HOOK"]
settings_path = os.environ["MEERKAT_SETTINGS"]

# Which lifecycle events Meerkat listens to, and the matcher for each.
#
# Deliberately absent: PreToolUse and PostToolUse. Those fire on every single
# tool call, and a status widget is not worth a subprocess per tool call.
# PostToolBatch fires once per round of tool calls instead, which is all the
# heartbeat we need.
EVENTS = [
    ("SessionStart", None),        # a session appears (new, resumed, cleared)
    ("UserPromptSubmit", None),    # it starts working on a turn
    ("PostToolBatch", None),       # heartbeat; also clears "needs you"
    ("Notification",               # it wants something from you
     "permission_prompt|idle_prompt|agent_needs_input"
     "|elicitation_dialog|elicitation_url_dialog"),
    ("TaskCreated", None),         # its task list grew
    ("TaskCompleted", None),       # ... and shrank: this is the progress bar
    ("Stop", None),                # the turn finished  <- the one that matters
    ("StopFailure", None),         # the turn died on an API error
    ("SessionEnd", None),          # it is gone; drop the row
]


def is_ours(handler):
    """True for a hook handler that belongs to Meerkat, old or new."""
    if not isinstance(handler, dict):
        return False
    blob = json.dumps(handler)
    return "meerkat-hook" in blob


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read().strip()
    if not text:
        return {}
    try:
        data = json.loads(text)
    except ValueError as exc:
        sys.stderr.write(
            "\n%s is not valid JSON, so it was left untouched.\n"
            "Fix the file (%s) and run this again.\n" % (path, exc))
        sys.exit(1)
    if not isinstance(data, dict):
        sys.stderr.write("\n%s does not contain a JSON object.\n" % path)
        sys.exit(1)
    return data


def strip_meerkat(settings):
    """Remove every Meerkat handler, so installing twice is a no-op."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event in list(hooks.keys()):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict):
                kept_groups.append(group)
                continue
            handlers = group.get("hooks")
            if isinstance(handlers, list):
                remaining = [h for h in handlers if not is_ours(h)]
                if not remaining:
                    # The whole group was ours; drop it.
                    continue
                group = dict(group)
                group["hooks"] = remaining
            kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]
    if not hooks:
        settings.pop("hooks", None)


def add_meerkat(settings):
    hooks = settings.setdefault("hooks", {})
    for event, matcher in EVENTS:
        handler = {
            "type": "command",
            # Exec form: the interpreter is the executable and the script is an
            # argument, so nothing depends on a shebang, an exec bit, or PATH.
            "command": python,
            "args": [hook],
            # Several of these events block the session until the hook returns.
            # Five seconds is far more than a small file write needs, and it
            # fails open if something ever goes wrong.
            "timeout": 5,
        }
        group = {"hooks": [handler]}
        if matcher:
            group["matcher"] = matcher
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            sys.stderr.write(
                "\nhooks.%s in your settings is not a list; leaving it alone.\n" % event)
            continue
        groups.append(group)


settings = load(settings_path)
before = json.dumps(settings, sort_keys=True)

strip_meerkat(settings)
if mode != "uninstall":
    add_meerkat(settings)

after = json.dumps(settings, sort_keys=True)

if mode == "dry-run":
    print(json.dumps(settings, indent=2))
    sys.exit(0)

if before == after:
    print("settings already up to date -> %s" % settings_path)
    sys.exit(0)

if os.path.exists(settings_path):
    backup = "%s.meerkat-backup-%s" % (settings_path, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(settings_path, backup)
    print("backup -> %s" % backup)

tmp = settings_path + ".meerkat.tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
os.replace(tmp, settings_path)

verb = "removed from" if mode == "uninstall" else "installed into"
print("hooks  %s %s" % (verb, settings_path))
PYEOF

if [ "$MODE" = "dry-run" ]; then
  exit 0
fi

if [ "$MODE" = "uninstall" ]; then
  echo
  echo "Meerkat's hooks are gone. The state folder is still at $MEERKAT_HOME"
  echo "if you want it: rm -rf $MEERKAT_HOME"
  exit 0
fi

cat <<'MSG'

Done. Two things to know:

  * Already-open Claude Code sessions do not pick up new hooks. Start a new
    session, or run /clear in an existing one.
  * Hooks only run in a folder whose workspace trust you have accepted.

Next:  ./build.sh && open build/Meerkat.app
Check: ./scripts/doctor.sh
MSG
