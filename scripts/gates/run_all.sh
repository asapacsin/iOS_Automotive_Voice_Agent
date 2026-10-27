#!/usr/bin/env bash
# Runs the static and unit gates that work without Xcode (ai-agent-workflow.md, ios-architecture §13).
# Usage: scripts/gates/run_all.sh [ACCEPTANCE_ID ...]   (no IDs: every ID in specs/trace-ids.txt)
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 -m unittest discover -s "$root/scripts/gates/tests"
python3 "$root/scripts/gates/check_runners.py"
python3 "$root/scripts/gates/check_imports.py"
python3 "$root/scripts/gates/check_secrets.py"
for pkg in NovaCore NovaRealtime NovaServices; do
  echo "== build + unit: $pkg"
  swift build --package-path "$root/Packages/$pkg" -Xswiftc -warnings-as-errors
  if [ -d "$root/Packages/$pkg/Tests" ]; then swift test --package-path "$root/Packages/$pkg"; fi
done
python3 "$root/scripts/ios_spec_check.py"
python3 "$root/scripts/gates/spec_trace.py" "$@"
echo "gates: PASS"
