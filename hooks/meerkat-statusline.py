#!/usr/bin/env python3
"""
Meerkat usage harvester.

Claude Code hands the status line script a JSON blob on stdin that contains the
one thing no hook ever sees: your remaining plan quota. This script captures
that into ~/.meerkat/usage.json for the widget to read, then renders a status
line so the terminal still shows something useful.

If you already had a status line, enable-usage.sh saved its command and this
script runs it and passes its output straight through, so your own status line
keeps working unchanged.

Unlike the hook, this one DOES write to stdout: that is the whole contract of a
status line. It still always exits 0, because a non-zero exit blanks the bar.
"""

import json
import os
import subprocess
import sys
import time


def home():
    return os.environ.get("MEERKAT_HOME") or os.path.join(
        os.path.expanduser("~"), ".meerkat")


def save(payload):
    """Pull the quota numbers out and record them with a timestamp."""
    base = home()
    os.makedirs(base, exist_ok=True)

    # Keep one raw payload around. It is the only way to see what fields this
    # particular Claude Code version actually sends.
    raw_path = os.path.join(base, "statusline-payload.json")
    tmp = raw_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
    os.replace(tmp, raw_path)

    limits = payload.get("rate_limits")
    if not isinstance(limits, dict):
        return

    # Deliberately not hardcoding five_hour/seven_day: whatever windows this
    # version reports get carried through, so a new limit appears on its own.
    windows = {}
    for key, value in limits.items():
        if not isinstance(value, dict):
            continue
        entry = {}
        for field in ("used_percentage", "resets_at", "used_usd",
                      "limit_usd", "period"):
            if value.get(field) is not None:
                entry[field] = value[field]
        if entry:
            windows[key] = entry

    if not windows:
        return

    record = {
        "version": 1,
        "captured": time.time(),
        "source": payload.get("version") or "",
        "windows": windows,
    }
    usage_path = os.path.join(base, "usage.json")
    tmp = usage_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(record, fh)
    os.replace(tmp, usage_path)


def passthrough(raw):
    """Run the status line that was configured before Meerkat, if any."""
    prior_path = os.path.join(home(), "prior-statusline")
    if not os.path.exists(prior_path):
        return None
    try:
        with open(prior_path, "r", encoding="utf-8") as fh:
            command = fh.read().strip()
        if not command:
            return None
        result = subprocess.run(
            command, shell=True, input=raw, capture_output=True,
            text=True, timeout=5)
        if result.returncode == 0 and result.stdout:
            return result.stdout.rstrip("\n")
    except Exception:
        pass
    return None


def bar(percent, width=10):
    filled = int(round(max(0.0, min(100.0, percent)) / 100.0 * width))
    return "▓" * filled + "░" * (width - filled)


def render(payload):
    """A compact default status line, used when you had none of your own."""
    parts = []

    model = (payload.get("model") or {}).get("display_name")
    if model:
        parts.append(str(model))

    context = payload.get("context_window") or {}
    used = context.get("used_percentage")
    if used is not None:
        parts.append("ctx %d%%" % int(used))

    limits = payload.get("rate_limits") or {}
    labels = {"five_hour": "5h", "seven_day": "7d", "spend_limit": "spend"}
    for key in ("five_hour", "seven_day", "spend_limit"):
        window = limits.get(key)
        if isinstance(window, dict) and window.get("used_percentage") is not None:
            parts.append("%s %s %d%%" % (
                labels[key], bar(float(window["used_percentage"]), 8),
                int(window["used_percentage"])))

    # Anything this version reports that we did not name above.
    for key, window in sorted(limits.items()):
        if key in labels or not isinstance(window, dict):
            continue
        if window.get("used_percentage") is not None:
            parts.append("%s %d%%" % (key, int(window["used_percentage"])))

    return "  ".join(parts) if parts else ""


def main():
    raw = sys.stdin.read()
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        return

    try:
        save(payload)
    except Exception:
        # Capturing is a side errand; never let it blank the status bar.
        if os.environ.get("MEERKAT_DEBUG"):
            import traceback
            traceback.print_exc(file=sys.stderr)

    line = passthrough(raw)
    if line is None:
        line = render(payload)
    if line:
        sys.stdout.write(line + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        if os.environ.get("MEERKAT_DEBUG"):
            import traceback
            traceback.print_exc(file=sys.stderr)
    sys.exit(0)
