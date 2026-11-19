#!/usr/bin/env bash
# Runs the static and unit gates that work without Xcode (ai-agent-workflow.md, ios-architecture §13).
# Usage: scripts/gates/run_all.sh [ACCEPTANCE_ID ...]   (no IDs: every ID in specs/trace-ids.txt)
# The Python-only part is scripts/gates/run_static.sh (CI job `static`, specs/ci-linux.md).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
"$root/scripts/gates/run_static.sh" "$@"
for pkg in NovaCore NovaRealtime NovaServices; do
  echo "== build + unit: $pkg"
  swift build --package-path "$root/Packages/$pkg" -Xswiftc -warnings-as-errors
  if [ -d "$root/Packages/$pkg/Tests" ]; then swift test --package-path "$root/Packages/$pkg"; fi
done
# Spec checks last, so the tail of the output is the final word.
python3 "$root/scripts/ios_spec_check.py"
python3 "$root/scripts/gates/spec_trace.py" "$@"
echo "gates: PASS"
