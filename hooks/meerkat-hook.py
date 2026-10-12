#!/usr/bin/env python3
"""
Meerkat hook — the sentry that watches Claude Code and reports to the desktop widget.

Claude Code pipes one JSON object per lifecycle event into this script on stdin.
We fold that into a small per-session state file that the Meerkat.app window reads.

Three hard rules, because this script runs inside Claude Code's critical path:

  1. NOTHING goes to stdout. On SessionStart and UserPromptSubmit, Claude Code
     injects a hook's plain stdout straight into Claude's context window. A stray
     print() here would start whispering into your conversations.
  2. ALWAYS exit 0. Exit code 2 on Stop prevents Claude from stopping; on
     TaskCreated it rolls back the task. A crashing status widget must never be
     able to wedge a real session.
  3. Be fast. UserPromptSubmit, Stop, TaskCreated and TaskCompleted all block
     until we return. Everything here is a few-millisecond file write.

State lives in ~/.meerkat/sessions/<session_id>.json (override with $MEERKAT_HOME).
"""

import json
import os
import sys
import time

STATE_VERSION = 1

# How long a session file survives without updates before we consider it debris
# from a crashed session and sweep it away.
STALE_AFTER_SECONDS = 24 * 60 * 60

DETAIL_MAX_CHARS = 110


def home() -> str:
    return os.environ.get("MEERKAT_HOME") or os.path.join(
        os.path.expanduser("~"), ".meerkat"
    )


def sessions_dir() -> str:
    return os.path.join(home(), "sessions")


def session_path(session_id: str) -> str:
    # session_id comes from Claude Code, but it lands in a filesystem path, so
    # keep it to characters that cannot walk out of the directory.
    safe = "".join(c for c in session_id if c.isalnum() or c in "-_")
    if not safe:
        safe = "unknown"
    return os.path.join(sessions_dir(), safe + ".json")


def tidy(text, limit=DETAIL_MAX_CHARS):
    """Collapse a blob of prompt or message text into one short display line."""
    if not text:
        return ""
    if not isinstance(text, str):
        return ""
    # Drop the pasted-content markers Claude Code wraps around large pastes,
    # then flatten to a single line.
    lines = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("<pasted_content") or line.startswith("</pasted_content"):
            continue
        lines.append(line)
    flat = " ".join(lines)
    flat = " ".join(flat.split())
    if len(flat) > limit:
        flat = flat[: limit - 1].rstrip() + "…"
    return flat


class Lock:
    """
    Tiny advisory lock so two events in the same session cannot interleave a
    read-modify-write. macOS has no flock(1), so we use an exclusive-create
    file, which is atomic on every filesystem we care about.

    If we cannot get the lock quickly we proceed anyway: a slightly stale task
    counter is a far better outcome than stalling someone's prompt.
    """

    def __init__(self, path, timeout=0.75):
        self.path = path + ".lock"
        self.timeout = timeout
        self.fd = None

    def __enter__(self):
        deadline = time.time() + self.timeout
        while True:
            try:
                self.fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                return self
            except FileExistsError:
                # Break a lock abandoned by a killed process.
                try:
                    if time.time() - os.path.getmtime(self.path) > 5:
                        os.unlink(self.path)
                        continue
                except OSError:
                    pass
                if time.time() >= deadline:
                    return self
                time.sleep(0.01)
            except OSError:
                return self

    def __exit__(self, *_):
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            try:
                os.unlink(self.path)
            except OSError:
                pass
        return False


def read_state(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            return data
    except (OSError, ValueError):
        pass
    return {}


def write_state(path, data):
    """Write atomically so the watching app never reads a half-written file."""
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, path)


def sweep_stale():
    """Remove session files left behind by sessions that died without SessionEnd."""
    now = time.time()
    try:
        names = os.listdir(sessions_dir())
    except OSError:
        return
    for name in names:
        if not name.endswith(".json"):
            continue
        full = os.path.join(sessions_dir(), name)
        try:
            if now - os.path.getmtime(full) > STALE_AFTER_SECONDS:
                os.unlink(full)
        except OSError:
            pass


def label_for(event):
    """A short human name for the session: its title if set, else its folder."""
    title = event.get("session_title")
    if isinstance(title, str) and title.strip():
        return tidy(title, 40)
    cwd = event.get("cwd")
    if isinstance(cwd, str) and cwd.strip():
        base = os.path.basename(cwd.rstrip("/"))
        if base:
            return tidy(base, 40)
    return "session"


def apply(event, state):
    """
    Fold one hook event into the session's state.

    Returns the new state dict, or None to delete the session file.

    States: idle | working | attention | done | failed
    """
    name = event.get("hook_event_name") or ""
    now = time.time()

    def moved_to(new_state):
        """Stamp a state change, keeping `since` stable if the state is unchanged."""
        if state.get("state") != new_state:
            state["since"] = now
        state["state"] = new_state

    if name == "SessionEnd":
        return None

    # Fields worth refreshing on every event we handle.
    state["version"] = STATE_VERSION
    state["session_id"] = event.get("session_id") or ""
    state["updated"] = now
    if event.get("cwd"):
        state["cwd"] = event.get("cwd")
    new_label = label_for(event)
    # cwd/title are absent on some events; never overwrite a good label with a
    # generic fallback.
    if new_label != "session" or not state.get("label"):
        state["label"] = new_label
    state.setdefault("since", now)
    state.setdefault("tasks_total", 0)
    state.setdefault("tasks_done", 0)
    state.setdefault("turns", 0)
    state.setdefault("detail", "")
    state.setdefault("waiting_for", "")
    state.setdefault("state", "idle")

    if name == "SessionStart":
        # A fresh session, or one resumed/cleared/compacted. Task counters
        # describe the current task list, which does not survive a clear, so
        # reset them rather than letting them drift upward forever.
        source = event.get("source") or ""
        if source in ("startup", "clear", "fork"):
            state["tasks_total"] = 0
            state["tasks_done"] = 0
            state["turns"] = 0
            state["detail"] = ""
        state["waiting_for"] = ""
        if event.get("model"):
            state["model"] = event.get("model")
        moved_to("idle")

    elif name == "UserPromptSubmit":
        state["detail"] = tidy(event.get("prompt"))
        state["waiting_for"] = ""
        state["turns"] = int(state.get("turns") or 0) + 1
        moved_to("working")

    elif name == "PostToolBatch":
        # Fires once per round of tool calls: our heartbeat. Reaching here means
        # tools are actually executing, so whatever Claude was waiting on (a
        # permission prompt, a question) has been answered and work resumed.
        # That recovers every non-working state, a prior failure included.
        moved_to("working")
        state["waiting_for"] = ""

    elif name == "Notification":
        kind = event.get("notification_type") or event.get("type") or ""
        message = tidy(event.get("message"), 60)
        if kind == "idle_prompt":
            # Claude has been sitting idle waiting for input. That is only news
            # if we thought it was busy; it is noise right after a normal finish.
            if state.get("state") == "working":
                state["waiting_for"] = message or "waiting for you"
                moved_to("attention")
        else:
            pretty = {
                "permission_prompt": "needs permission",
                "agent_needs_input": "needs input",
                "elicitation_dialog": "needs input",
                "elicitation_url_dialog": "needs sign-in",
            }.get(kind, message or "needs you")
            state["waiting_for"] = pretty
            moved_to("attention")

    elif name == "TaskCreated":
        state["tasks_total"] = int(state.get("tasks_total") or 0) + 1

    elif name == "TaskCompleted":
        state["tasks_done"] = int(state.get("tasks_done") or 0) + 1
        total = int(state.get("tasks_total") or 0)
        if state["tasks_done"] > total:
            # We count events rather than reading the list, so a task created
            # before Meerkat was installed can push done past total. Keep the
            # ratio honest instead of showing 4/3.
            state["tasks_total"] = state["tasks_done"]

    elif name == "Stop":
        # Deliberately NOT storing last_assistant_message here. Showing Claude's
        # reply turns the widget into a chat transcript; what you want to see on
        # a finished row is which task finished, so `detail` stays as the prompt
        # that started the turn.
        state["waiting_for"] = ""
        moved_to("done")

    elif name == "StopFailure":
        kind = event.get("error_type") or event.get("error") or "error"
        state["waiting_for"] = tidy(str(kind), 40)
        moved_to("failed")

    return state


def main():
    raw = sys.stdin.read()
    event = json.loads(raw)
    if not isinstance(event, dict):
        return

    session_id = event.get("session_id")
    if not session_id:
        return

    os.makedirs(sessions_dir(), exist_ok=True)

    if event.get("hook_event_name") == "SessionStart":
        sweep_stale()

    path = session_path(session_id)
    with Lock(path):
        state = read_state(path)
        updated = apply(event, state)
        if updated is None:
            try:
                os.unlink(path)
            except OSError:
                pass
        else:
            write_state(path, updated)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Rule 2. Whatever went wrong, it is not worth breaking a session over.
        # Set MEERKAT_DEBUG=1 to see the traceback on stderr (never stdout).
        if os.environ.get("MEERKAT_DEBUG"):
            import traceback

            traceback.print_exc(file=sys.stderr)
    sys.exit(0)
