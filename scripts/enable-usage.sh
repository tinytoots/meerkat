#!/bin/bash
# Turns on plan-usage capture.
#
#   ./scripts/enable-usage.sh            install
#   ./scripts/enable-usage.sh --disable  remove and restore your old status line
#
# Claude Code reports your remaining quota to exactly one place: the terminal
# status line script. This registers a script that captures those numbers into
# ~/.meerkat/usage.json for the widget, then renders a status line as usual.
#
# If you already have a status line, its command is saved and run by ours, with
# its output passed straight through, so your terminal looks unchanged.

set -euo pipefail
cd "$(dirname "$0")/.."

HERE="$(pwd)"
MEERKAT_HOME="$HOME/.meerkat"
SETTINGS="$HOME/.claude/settings.json"
MODE="install"

for arg in "$@"; do
  case "$arg" in
    --disable) MODE="disable" ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "python3 not found; run xcode-select --install" >&2; exit 1; }

mkdir -p "$MEERKAT_HOME"
if [ "$MODE" = "install" ]; then
  install -m 0755 "$HERE/hooks/meerkat-statusline.py" "$MEERKAT_HOME/meerkat-statusline.py"
  echo "harvester -> $MEERKAT_HOME/meerkat-statusline.py"
fi

MEERKAT_MODE="$MODE" \
MEERKAT_PY="$PY" \
MEERKAT_SCRIPT="$MEERKAT_HOME/meerkat-statusline.py" \
MEERKAT_PRIOR="$MEERKAT_HOME/prior-statusline" \
MEERKAT_SETTINGS="$SETTINGS" \
"$PY" - <<'PYEOF'
import json
import os
import shutil
import sys
import time

mode = os.environ["MEERKAT_MODE"]
python = os.environ["MEERKAT_PY"]
script = os.environ["MEERKAT_SCRIPT"]
prior_path = os.environ["MEERKAT_PRIOR"]
settings_path = os.environ["MEERKAT_SETTINGS"]

settings = {}
if os.path.exists(settings_path):
    with open(settings_path, "r", encoding="utf-8") as fh:
        text = fh.read().strip()
    if text:
        try:
            settings = json.loads(text)
        except ValueError as exc:
            sys.stderr.write("\n%s is not valid JSON (%s); left untouched.\n"
                             % (settings_path, exc))
            sys.exit(1)

current = settings.get("statusLine")
ours = "meerkat-statusline" in json.dumps(current) if current else False

if mode == "disable":
    if not ours:
        print("Meerkat is not your status line; nothing changed.")
        sys.exit(0)
    if os.path.exists(prior_path):
        with open(prior_path, "r", encoding="utf-8") as fh:
            restored = fh.read().strip()
        if restored:
            settings["statusLine"] = {"type": "command", "command": restored}
            print("restored your previous status line: %s" % restored)
        else:
            settings.pop("statusLine", None)
        os.remove(prior_path)
    else:
        settings.pop("statusLine", None)
        print("removed the status line")
else:
    # Preserve whatever was there, so their terminal keeps looking the same.
    if current and not ours:
        if isinstance(current, dict) and current.get("type") == "command":
            existing = current.get("command")
            if isinstance(existing, str) and existing.strip():
                with open(prior_path, "w", encoding="utf-8") as fh:
                    fh.write(existing.strip())
                print("saved your existing status line; it will still run:")
                print("    %s" % existing.strip())
        else:
            sys.stderr.write(
                "\nYour statusLine is not a simple command, so it cannot be\n"
                "chained. Meerkat will replace it. Your settings backup has\n"
                "the original if you want it back.\n")
    settings["statusLine"] = {
        "type": "command",
        "command": "%s %s" % (python, script),
        # The quota figures only refresh when Claude Code re-runs this, so ask
        # for a tick even while the session sits idle.
        "refreshInterval": 30,
    }

if os.path.exists(settings_path):
    backup = "%s.meerkat-backup-%s" % (settings_path, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(settings_path, backup)
    print("backup -> %s" % backup)

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
tmp = settings_path + ".meerkat.tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
os.replace(tmp, settings_path)
print("statusLine %s %s"
      % ("removed from" if mode == "disable" else "installed into", settings_path))
PYEOF

if [ "$MODE" = "disable" ]; then
  rm -f "$MEERKAT_HOME/usage.json" "$MEERKAT_HOME/statusline-payload.json"
  echo "usage data cleared."
  exit 0
fi

cat <<'MSG'

Now open a NEW terminal session to test whether this surface reports quota:

    claude

Send it anything, then in another terminal:

    ./scripts/check-usage.sh

That prints what was captured, or tells you nothing arrived.
MSG
