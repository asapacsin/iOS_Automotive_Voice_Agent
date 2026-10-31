#!/usr/bin/env bash
# Shows that a wrong checksum fails fetch_sherpa_models.sh and installs nothing.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Flip the first hex digit of the KWS tokens.txt line.
awk '$2 == "kws/tokens.txt" { $1 = (substr($1,1,1) == "0" ? "1" : "0") substr($1,2); $0 = $1 "  " $2 } { print }' \
  "$root/scripts/sherpa/models.sha256" > "$tmp/tampered.sha256"
if cmp -s "$tmp/tampered.sha256" "$root/scripts/sherpa/models.sha256"; then echo "FAIL: tampering did nothing"; exit 1; fi
if SHERPA_SHA_FILE="$tmp/tampered.sha256" "$root/scripts/fetch_sherpa_models.sh" "$tmp/out" 2> "$tmp/err"; then
  echo "FAIL: script accepted a wrong checksum"; exit 1
fi
grep -q "CHECKSUM MISMATCH" "$tmp/err" || { echo "FAIL: no clear mismatch message"; cat "$tmp/err"; exit 1; }
[ ! -e "$tmp/out" ] || { echo "FAIL: files installed despite mismatch"; exit 1; }
echo "test_checksum_failure: PASS"
