#!/bin/bash
# Checks the plan-usage parsers in Sources/Models.swift against canned replies.
# No network, no keychain, no window: it compiles Models.swift together with
# scripts/usage_parse_check.swift into a temp directory and runs the result.
#
#   ./scripts/usage-parse-check.sh

set -euo pipefail
cd "$(dirname "$0")/.."

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

swiftc -parse-as-library \
  -target "$(uname -m)-apple-macosx13.0" \
  Sources/Models.swift \
  scripts/usage_parse_check.swift \
  -o "$out/usage-parse-check"

"$out/usage-parse-check"
