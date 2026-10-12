#!/bin/bash
# Fills the widget with fake sessions so you can see every state at once,
# including the ones you would rarely catch in the wild.
#
#   ./scripts/demo.sh
#
# Writes directly into ~/.meerkat/sessions/ using the demo- prefix, then removes
# exactly those files when you press Return. Your real sessions are untouched.

set -u

DIR="$HOME/.meerkat/sessions"
PY="${PYTHON:-python3}"
mkdir -p "$DIR"

USAGE="$HOME/.meerkat/usage.json"
SAVED="$HOME/.meerkat/usage.json.demo-saved"

CLEANED=0
cleanup() {
  # Once only. Ctrl-C runs this from the INT trap and then again from EXIT,
  # and a second run would find nothing set aside and delete the real
  # usage.json the first run had just put back.
  [ "$CLEANED" = "1" ] && return
  CLEANED=1
  rm -f "$DIR"/demo-*.json
  # Put back any real captured usage, or remove the demo figures entirely.
  if [ -f "$SAVED" ]; then
    mv "$SAVED" "$USAGE"
    echo "demo cleared; your real captured usage is back."
  else
    rm -f "$USAGE"
    echo "demo cleared."
  fi
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

"$PY" - "$DIR" <<'PYEOF'
import json, os, sys, time
d = sys.argv[1]
now = time.time()

# One of each state, with the kind of content a real session produces.
rows = [
    dict(id="demo-1", label="api-server", state="attention",
         detail="Run the migration against staging",
         waiting_for="needs permission", since=now - 14, turns=3,
         tasks_total=0, tasks_done=0),
    dict(id="demo-2", label="meerkat", state="working",
         detail="Wire the progress bar to TaskCompleted events",
         waiting_for="", since=now - 162, turns=7,
         tasks_total=5, tasks_done=3),
    dict(id="demo-3", label="web-frontend", state="done",
         detail="Fixed it. The token TTL was in seconds, not milliseconds.",
         waiting_for="", since=now - 48, turns=11,
         tasks_total=4, tasks_done=4),
    dict(id="demo-4", label="data-pipeline", state="failed",
         detail="Backfill the June partitions",
         waiting_for="rate_limit", since=now - 420, turns=2,
         tasks_total=0, tasks_done=0),
    dict(id="demo-5", label="notes", state="idle",
         detail="", waiting_for="", since=now - 90, turns=1,
         tasks_total=0, tasks_done=0),
]

for row in rows:
    state = {
        "version": 1,
        "session_id": row["id"],
        "label": row["label"],
        "cwd": "/Users/you/code/" + row["label"],
        "state": row["state"],
        "detail": row["detail"],
        "waiting_for": row["waiting_for"],
        "since": row["since"],
        "updated": now,
        "tasks_total": row["tasks_total"],
        "tasks_done": row["tasks_done"],
        "turns": row["turns"],
    }
    path = os.path.join(d, row["id"] + ".json")
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, path)

print("wrote %d demo sessions" % len(rows))
PYEOF

# Fake plan-usage figures, so the usage block renders even on a machine where
# nothing can capture the real ones. Any genuinely captured file is set aside
# and restored on the way out.
[ -f "$USAGE" ] && mv "$USAGE" "$SAVED"
"$PY" - "$USAGE" <<'PYEOF'
import json, sys, time
now = time.time()
json.dump({
    "version": 1,
    "captured": now,
    "source": "demo",
    "windows": {
        "five_hour": {"used_percentage": 16.0, "resets_at": now + 5100},
        "seven_day": {"used_percentage": 81.0, "resets_at": now + 124000},
        "fable_seven_day": {"used_percentage": 100.0, "resets_at": now + 124000},
    },
}, open(sys.argv[1], "w"))
print("wrote demo usage figures (these are FAKE, for layout only)")
PYEOF

cat <<'MSG'

The widget should now show the full layout. Worth checking:

  PLAN USAGE -- three bars, green/amber/red by how full they are. If
  Meerkat has fetched your real figures from claude.ai in the last half
  hour, those stay up and these FAKE ones (16/81/100%) never show; turn
  plan usage off from the menu first to see them. Hover a bar for its
  reset time.

  * The header meerkat wears the most urgent state, so it should be the
    "needs you" one: eyes wide, bobbing, orange ! above its head.
  * api-server      -> orange dot, "needs permission", "needs you · 14s"
  * meerkat         -> amber pulsing dot, "3/5 · 2m" and a progress bar
  * web-frontend    -> green tick, "done · 48s", a full progress bar
  * data-pipeline   -> red dot, "rate_limit", "failed · 7m"
  * notes           -> grey dot, dozing
  * Click the meerkat to collapse to a puck; click it again to expand.
  * Drag it around, both collapsed and expanded.
  * Right-click for the menu.

MSG
read -r -p "Press Return to clear the demo sessions... " _
