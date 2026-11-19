#!/usr/bin/env bash
# The Python-only gates (no Swift), specs/ci-linux.md §3 item 1. run_all.sh runs these, then Swift, then spec checks.
# Usage: scripts/gates/run_static.sh [ACCEPTANCE_ID ...]
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 -m unittest discover -s "$root/scripts/gates/tests"
python3 "$root/scripts/gates/check_runners.py"
python3 "$root/scripts/gates/check_imports.py"
python3 "$root/scripts/gates/check_secrets.py"
python3 "$root/scripts/gates/check_kws_tokens.py"
python3 "$root/scripts/ios_spec_check.py"
python3 "$root/scripts/gates/spec_trace.py" "$@"
echo "static gates: PASS"
