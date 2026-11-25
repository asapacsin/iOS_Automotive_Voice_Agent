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
python3 "$root/scripts/gates/check_paid_scripts.py"  # F-18 §32 item 6 (T-046u)
python3 "$root/scripts/gates/check_qwen_models.py"  # F-18 §40 row 58 (T-046zc)
python3 "$root/scripts/gates/check_record_format.py"  # F-12 §21 item 4 (T-031u)
python3 "$root/scripts/gates/check_agent_version.py"  # F-09b §15 item 5 (T-031y)
python3 "$root/scripts/gates/check_single_types.py"  # F-09b §16 item 10 (T-031z)
python3 "$root/scripts/gates/check_panel_tools.py"  # F-09b §17 item 3 (T-031zb)
# F-09b §13 item 8: strict from the end of stage 3 (T-031n).
python3 "$root/scripts/gates/check_scripts.py" --strict
python3 "$root/scripts/history.py" check
python3 "$root/scripts/ios_spec_check.py"
python3 "$root/scripts/gates/spec_trace.py" "$@"
echo "static gates: PASS"
