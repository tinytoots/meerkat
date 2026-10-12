#!/bin/bash
# Checks that Meerkat is wired up, and says what to do about anything that is not.
#
#   ./scripts/doctor.sh

set -u
cd "$(dirname "$0")/.."

MEERKAT_HOME_DIR="$HOME/.meerkat"
SETTINGS="$HOME/.claude/settings.json"
PY="$(command -v python3 || true)"

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mno\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33m??\033[0m    %s\n' "$1"; }
note() { printf '        %s\n' "$1"; }

echo
echo "Meerkat doctor"
echo "=============="
echo

echo "python3"
if [ -n "$PY" ]; then
  ok "$PY ($("$PY" -V 2>&1))"
else
  bad "not found"
  note "xcode-select --install"
fi

echo
echo "hook script"
if [ -x "$MEERKAT_HOME_DIR/meerkat-hook.py" ]; then
  ok "$MEERKAT_HOME_DIR/meerkat-hook.py"
  if diff -q hooks/meerkat-hook.py "$MEERKAT_HOME_DIR/meerkat-hook.py" >/dev/null 2>&1; then
    ok "matches this checkout"
  else
    warn "differs from this checkout — run ./install.sh to update it"
  fi
else
  bad "not installed"
  note "./install.sh"
fi

echo
echo "claude code settings"
if [ ! -f "$SETTINGS" ]; then
  bad "$SETTINGS does not exist"
  note "./install.sh"
elif [ -z "$PY" ]; then
  warn "cannot inspect settings without python3"
else
  "$PY" - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception as exc:
    print("  \033[31mno\033[0m    %s is not valid JSON (%s)" % (path, exc))
    sys.exit(0)

hooks = data.get("hooks") or {}
mine = {}
for event, groups in hooks.items():
    if not isinstance(groups, list):
        continue
    n = 0
    for group in groups:
        if isinstance(group, dict):
            for handler in group.get("hooks") or []:
                if "meerkat-hook" in json.dumps(handler):
                    n += 1
    if n:
        mine[event] = n

wanted = {"SessionStart", "UserPromptSubmit", "PostToolBatch", "Notification",
          "TaskCreated", "TaskCompleted", "Stop", "StopFailure", "SessionEnd"}

if not mine:
    print("  \033[31mno\033[0m    no Meerkat hooks registered")
    print("        ./install.sh")
else:
    print("  \033[32mok\033[0m    %d events wired: %s"
          % (len(mine), ", ".join(sorted(mine))))
    missing = wanted - set(mine)
    if missing:
        print("  \033[33m??\033[0m    missing: %s" % ", ".join(sorted(missing)))
        print("        ./install.sh")
    dupes = {e: n for e, n in mine.items() if n > 1}
    if dupes:
        print("  \033[33m??\033[0m    duplicated: %s" % dupes)
        print("        ./install.sh --uninstall && ./install.sh")

if data.get("disableAllHooks") is True:
    print("  \033[31mno\033[0m    disableAllHooks is true — no hooks will run at all")
    print("        remove that key from %s" % path)
PYEOF
fi

echo
echo "hook actually runs"
if [ -n "$PY" ] && [ -f "$MEERKAT_HOME_DIR/meerkat-hook.py" ]; then
  probe="$(mktemp -d)"
  out=$(echo '{"hook_event_name":"UserPromptSubmit","session_id":"doctor-probe","cwd":"/tmp/doctor","prompt":"ping"}' \
    | MEERKAT_HOME="$probe" "$PY" "$MEERKAT_HOME_DIR/meerkat-hook.py" 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    bad "exited $rc"
    note "$out"
  elif [ -n "$out" ]; then
    bad "wrote to stdout/stderr: $out"
    note "stdout from a hook is injected into Claude's context; this must be silent"
  elif [ -f "$probe/sessions/doctor-probe.json" ]; then
    ok "processed a synthetic event and wrote state"
  else
    bad "ran but wrote no state file"
  fi
  rm -rf "$probe"
else
  warn "skipped"
fi

echo
echo "live sessions"
if [ -d "$MEERKAT_HOME_DIR/sessions" ]; then
  count=$(ls -1 "$MEERKAT_HOME_DIR/sessions"/*.json 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" = "0" ]; then
    warn "none yet"
    note "open a Claude Code session and send it a prompt"
  else
    ok "$count session file(s)"
    [ -n "$PY" ] && "$PY" - "$MEERKAT_HOME_DIR/sessions" <<'PYEOF'
import json, os, sys, time
d = sys.argv[1]
for name in sorted(os.listdir(d)):
    if not name.endswith(".json"):
        continue
    try:
        with open(os.path.join(d, name)) as fh:
            s = json.load(fh)
    except Exception:
        print("        %s (unreadable)" % name)
        continue
    age = int(time.time() - (s.get("updated") or 0))
    print("        %-22s %-9s %s/%s  %ds ago  %s" % (
        s.get("label", "?"), s.get("state", "?"),
        s.get("tasks_done", 0), s.get("tasks_total", 0), age,
        (s.get("detail") or "")[:40]))
PYEOF
  fi
else
  warn "$MEERKAT_HOME_DIR/sessions does not exist yet"
fi

echo
echo "app"
if [ -d build/Meerkat.app ]; then
  ok "built at build/Meerkat.app"
else
  bad "not built"
  note "./build.sh"
fi
if pgrep -x Meerkat >/dev/null 2>&1; then
  ok "running (pid $(pgrep -x Meerkat | tr '\n' ' '))"
else
  warn "not running"
  note "open build/Meerkat.app"
fi

echo
echo "plan usage"
if [ "$(defaults read local.meerkat.widget usageFetchDisabled 2>/dev/null)" = "1" ]; then
  warn "turned off in Meerkat"
  note "right-click the window -> Turn on plan usage"
fi
# Existence only: no -w and no -g, so nothing secret is read or printed.
if security find-generic-password -a "${USER:-$(id -un)}" -s "Claude Code-credentials" \
     >/dev/null 2>&1; then
  ok "Claude Code sign-in found in the login keychain"
else
  rc=$?
  if [ "$rc" = "44" ]; then
    bad "no Claude Code sign-in in the login keychain"
    note "sign in to Claude Code with your Claude plan (Pro or Max)"
  else
    warn "could not check the login keychain (security exited $rc)"
    note "a locked keychain unlocks when you unlock your Mac"
  fi
fi
if [ -f "$MEERKAT_HOME_DIR/usage-api.json" ] && [ -n "$PY" ]; then
  "$PY" - "$MEERKAT_HOME_DIR/usage-api.json" <<'PYEOF'
import json, sys, time
try:
    with open(sys.argv[1]) as fh:
        note = json.load(fh)
except Exception:
    print("  \033[33m??\033[0m    last check is unreadable")
    sys.exit(0)
age = int(time.time() - (note.get("attempted") or 0))
if note.get("status") == "ok":
    print("  \033[32mok\033[0m    last check %ds ago: %d bar(s)"
          % (age, len(note.get("windows") or {})))
else:
    print("  \033[33m??\033[0m    last check %ds ago: %s" % (age, note.get("status", "?")))
PYEOF
  note "details: ./scripts/check-usage.sh"
elif pgrep -x Meerkat >/dev/null 2>&1; then
  warn "Meerkat is running but has not recorded a check"
  note "a build from before plan usage? ./build.sh, then quit and reopen it"
fi

echo
