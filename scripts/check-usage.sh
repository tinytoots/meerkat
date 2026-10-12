#!/bin/bash
# Reports the plan-usage figures Meerkat has, from both of its sources:
#
#   1. claude.ai -- what Meerkat.app itself last fetched from the usage
#      endpoint (~/.meerkat/usage-api.json). This is the normal source.
#   2. a terminal status line -- what the harvester last captured
#      (~/.meerkat/statusline-payload.json). Only a fallback now.
#
#   ./scripts/check-usage.sh           report what is there now
#   ./scripts/check-usage.sh --watch   wait for a status line to run
#
# With --watch, leave this running and go send a message in whichever Claude
# surface you want to test. It reports the moment that surface runs the status
# line script.

set -u
MEERKAT_HOME="$HOME/.meerkat"
PY="${PYTHON:-python3}"
WATCH=0
for arg in "$@"; do
  case "$arg" in
    --watch) WATCH=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$WATCH" = "1" ]; then
  echo
  echo "Watching for the status line to run. Go send a message in the surface"
  echo "you want to test: VS Code, the desktop app, or a terminal session."
  echo "Ctrl-C to stop."
  echo
  before=""
  [ -f "$MEERKAT_HOME/statusline-payload.json" ] && \
    before=$(stat -f %m "$MEERKAT_HOME/statusline-payload.json" 2>/dev/null \
             || stat -c %Y "$MEERKAT_HOME/statusline-payload.json" 2>/dev/null)
  waited=0
  while [ "$waited" -lt 300 ]; do
    if [ -f "$MEERKAT_HOME/statusline-payload.json" ]; then
      now=$(stat -f %m "$MEERKAT_HOME/statusline-payload.json" 2>/dev/null \
            || stat -c %Y "$MEERKAT_HOME/statusline-payload.json" 2>/dev/null)
      if [ "$now" != "$before" ]; then
        echo "  Something arrived after ${waited}s."
        break
      fi
    fi
    sleep 2
    waited=$((waited + 2))
    if [ $((waited % 20)) -eq 0 ]; then
      echo "  ...nothing yet (${waited}s)"
    fi
  done
  if [ "$waited" -ge 300 ]; then
    echo
    echo "  Five minutes, nothing. That surface does not run a status line."
    exit 1
  fi
fi

echo
API_RECORD="$MEERKAT_HOME/usage-api.json"
if [ -f "$API_RECORD" ]; then
  "$PY" - "$API_RECORD" <<'PYEOF'
import json, sys, time

path = sys.argv[1]
try:
    with open(path) as fh:
        note = json.load(fh)
except Exception as exc:
    print("From claude.ai: %s is unreadable (%s)" % (path, exc))
    sys.exit(0)

def ago(t):
    age = max(0, time.time() - t)
    return ("%dm" % (age // 60)) if age >= 60 else ("%ds" % age)

print("From claude.ai -- what Meerkat itself last fetched")
print()
if note.get("attempted"):
    print("  Last check %s ago: %s" % (ago(note["attempted"]), note.get("status", "?")))
windows = note.get("windows") or {}
if note.get("captured") and windows:
    print("  Figures from %s ago:" % ago(note["captured"]))
    print()
    rank = {"five_hour": 0, "seven_day": 1}
    for key in sorted(windows, key=lambda k: (rank.get(k, 2), k)):
        window = windows[key]
        pct = window.get("used_percentage")
        resets = window.get("resets_at")
        when = ""
        if resets:
            delta = resets - time.time()
            if delta > 0:
                when = "  resets %s" % time.strftime("%a %H:%M", time.localtime(resets))
            else:
                when = "  (reset time has passed)"
        shown = "%5.1f%%" % pct if pct is not None else "    ?"
        print("    %-20s %s%s" % (window.get("label", key), shown, when))
else:
    print("  No figures yet.")
print()
PYEOF
else
  cat <<'MSG'
From claude.ai -- nothing recorded yet.

  Meerkat.app writes ~/.meerkat/usage-api.json after every look at the usage
  endpoint. If it is running and this is missing, it is a build from before
  plan usage: ./build.sh, then quit and reopen it.

MSG
fi

echo "From a terminal status line"
echo
if [ ! -f "$MEERKAT_HOME/statusline-payload.json" ]; then
  if [ -f "$API_RECORD" ]; then
    echo "  Nothing captured. That is fine: Meerkat reads claude.ai directly, and"
    echo "  the status line is only a fallback for when it cannot."
    echo
    exit 0
  fi
  cat <<'MSG'
Nothing captured yet.

The status line script has not run even once, in any surface.

Leave this running and then send a message in whichever surface you want
to test:

    ./scripts/check-usage.sh --watch

Worth testing each one separately: VS Code, the desktop app's Code tab, and
a terminal session. Only a surface that renders a status line can report
your quota, and they do not all render one.
MSG
  exit 1
fi

"$PY" - "$MEERKAT_HOME" <<'PYEOF'
import json, os, sys, time

base = sys.argv[1]

with open(os.path.join(base, "statusline-payload.json")) as fh:
    payload = json.load(fh)

age = time.time() - os.path.getmtime(os.path.join(base, "statusline-payload.json"))
print("Captured %s ago, from Claude Code %s"
      % (("%dm" % (age / 60)) if age >= 60 else ("%ds" % age),
         payload.get("version", "?")))
print()

limits = payload.get("rate_limits")
if not isinstance(limits, dict) or not limits:
    print("  The payload arrived, but it carries NO rate_limits object.")
    print()
    print("  That means this surface and account do not report quota. The docs")
    print("  say rate_limits appears only for claude.ai Pro and Max subscribers,")
    print("  and only after the session's first API response -- so if you just")
    print("  started the session, send one more message and check again.")
    print()
    print("  Top-level keys present: %s" % ", ".join(sorted(payload)))
    sys.exit(1)

print("  rate_limits reported by your version:")
print()
for key in sorted(limits):
    window = limits[key]
    if not isinstance(window, dict):
        continue
    pct = window.get("used_percentage")
    resets = window.get("resets_at")
    when = ""
    if resets:
        delta = resets - time.time()
        if delta > 0:
            hours = int(delta // 3600)
            mins = int((delta % 3600) // 60)
            when = "  resets in %dh %02dm" % (hours, mins) if hours else "  resets in %dm" % mins
        else:
            when = "  (reset time has passed)"
    shown = "%5.1f%%" % pct if pct is not None else "    ?"
    print("    %-20s %s%s" % (key, shown, when))
    extra = {k: v for k, v in window.items()
             if k not in ("used_percentage", "resets_at")}
    if extra:
        print("    %-20s %s" % ("", extra))
print()
print("  Full payload: %s" % os.path.join(base, "statusline-payload.json"))
PYEOF
