#!/usr/bin/env bash
# Runs the static and unit gates that work without Xcode (ai-agent-workflow.md, ios-architecture §13).
# Usage: scripts/gates/run_all.sh [ACCEPTANCE_ID ...]
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$root/scripts/gates/check_imports.py"
python3 "$root/scripts/gates/check_secrets.py"
for pkg in NovaCore NovaRealtime NovaServices; do
  echo "== build + unit: $pkg"
  swift build --package-path "$root/Packages/$pkg" -Xswiftc -warnings-as-errors
  if [ -d "$root/Packages/$pkg/Tests" ]; then swift test --package-path "$root/Packages/$pkg"; fi
done
if [ "$#" -gt 0 ]; then python3 "$root/scripts/gates/spec_trace.py" "$@"; fi
echo "gates: PASS"
