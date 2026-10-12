#!/bin/bash
# Drives the hook script through a realistic session lifecycle and prints the
# resulting state after each event. Uses a throwaway state dir, so it never
# touches your real ~/.meerkat.
#
#   ./scripts/selftest.sh
#
# Expected arc: idle -> working -> attention (permission) -> working ->
# progress 1/3 .. 3/3 -> done -> (second turn) working -> failed -> gone.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/meerkat-hook.py"
export MEERKAT_HOME="$(mktemp -d)/meerkat"
export MEERKAT_DEBUG=1
SID="test-session-0001"
CWD="/Users/someone/AI_Projects/meerkat"
PY="${PYTHON:-python3}"

pass=0
fail=0

send() {
  echo "$1" | "$PY" "$HOOK"
}

# show <label> -> prints the one-line state summary
show() {
  "$PY" - "$MEERKAT_HOME/sessions/$SID.json" <<'PYEOF'
import json, sys, os
p = sys.argv[1]
if not os.path.exists(p):
    print("   (no state file)")
    sys.exit(0)
with open(p) as fh:
    s = json.load(fh)
print("   state=%-9s tasks=%s/%s turns=%s waiting=%-16s detail=%s" % (
    s.get("state"), s.get("tasks_done"), s.get("tasks_total"),
    s.get("turns"), repr(s.get("waiting_for")), repr(s.get("detail"))[:60]))
PYEOF
}

# expect <field> <value> -- assert on the current state file
expect() {
  local field="$1" want="$2"
  local got
  got=$("$PY" - "$MEERKAT_HOME/sessions/$SID.json" "$field" <<'PYEOF'
import json, sys, os
p, field = sys.argv[1], sys.argv[2]
if not os.path.exists(p):
    print("<missing>")
else:
    with open(p) as fh:
        print(json.load(fh).get(field))
PYEOF
)
  if [ "$got" = "$want" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "   !! FAIL: $field = '$got', expected '$want'"
  fi
}

expect_gone() {
  if [ -f "$MEERKAT_HOME/sessions/$SID.json" ]; then
    fail=$((fail+1)); echo "   !! FAIL: state file should have been deleted"
  else
    pass=$((pass+1))
  fi
}

echo "hook:  $HOOK"
echo "state: $MEERKAT_HOME"
echo

echo "1. SessionStart (startup)"
send "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"source\":\"startup\",\"model\":\"claude-opus-5\"}"
show; expect state idle; expect label meerkat

echo "2. UserPromptSubmit"
send "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"prompt\":\"Fix the login bug where\\n\\n  the session token expires early\"}"
show; expect state working; expect turns 1
expect detail "Fix the login bug where the session token expires early"

echo "3. Notification (permission_prompt) -> should grab your attention"
send "{\"hook_event_name\":\"Notification\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission to run npm test\"}"
show; expect state attention; expect waiting_for "needs permission"

echo "4. PostToolBatch -> permission answered, back to work"
send "{\"hook_event_name\":\"PostToolBatch\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
show; expect state working; expect waiting_for ""

echo "5. Three tasks created, two completed"
for i in 1 2 3; do send "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"; done
send "{\"hook_event_name\":\"TaskCompleted\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
send "{\"hook_event_name\":\"TaskCompleted\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
show; expect tasks_total 3; expect tasks_done 2

echo "6. Stop -> done, and the row still shows the TASK, not Claude's reply"
send "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"last_assistant_message\":\"Fixed it. The token TTL was in seconds, not ms.\"}"
show; expect state done
expect detail "Fix the login bug where the session token expires early"

echo "7. idle_prompt right after finishing -> must NOT flip to attention"
send "{\"hook_event_name\":\"Notification\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"notification_type\":\"idle_prompt\",\"message\":\"Claude is waiting for your input\"}"
show; expect state done

echo "8. Second turn, then idle_prompt while working -> attention"
send "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"prompt\":\"now add a regression test\"}"
expect turns 2
send "{\"hook_event_name\":\"Notification\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"notification_type\":\"idle_prompt\",\"message\":\"Claude is waiting for your input\"}"
show; expect state attention

echo "9. StopFailure -> failed"
send "{\"hook_event_name\":\"StopFailure\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"error_type\":\"rate_limit\"}"
show; expect state failed; expect waiting_for rate_limit

echo "10. Task overshoot (completed without a matching created) stays honest"
send "{\"hook_event_name\":\"TaskCompleted\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
send "{\"hook_event_name\":\"TaskCompleted\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
show; expect tasks_done 4; expect tasks_total 4

echo "11. Event with no cwd must not clobber the label"
send "{\"hook_event_name\":\"PostToolBatch\",\"session_id\":\"$SID\"}"
show; expect label meerkat

echo "12. SessionEnd -> state file removed"
send "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"reason\":\"other\"}"
show; expect_gone

echo "13. Garbage in -> silent exit 0, no crash"
echo 'not json at all' | "$PY" "$HOOK" 2>/dev/null; rc=$?
if [ $rc -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "   !! FAIL: exit $rc on bad input"; fi
printf '' | "$PY" "$HOOK" 2>/dev/null; rc=$?
if [ $rc -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "   !! FAIL: exit $rc on empty input"; fi

echo "14. Hook must never print to stdout (it would leak into Claude's context)"
out=$(send "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"other-1\",\"cwd\":\"$CWD\",\"prompt\":\"hi\"}" 2>/dev/null)
if [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "   !! FAIL: stdout was '$out'"; fi

echo "15. Path traversal in session_id is neutralised"
send "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"../../escape\",\"cwd\":\"$CWD\",\"prompt\":\"x\"}"
if [ -f "$MEERKAT_HOME/sessions/escape.json" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "   !! FAIL: expected sessions/escape.json"; fi

echo
echo "sessions dir now holds:"
ls -1 "$MEERKAT_HOME/sessions/" 2>/dev/null | sed 's/^/   /'
echo
echo "================================"
echo " passed: $pass    failed: $fail"
echo "================================"
rm -rf "$(dirname "$MEERKAT_HOME")"
[ "$fail" -eq 0 ]
