#!/usr/bin/env bash
# F-04b §12 item 6 (T-013f): builds the Apple-hosted speaker model asset pack (.aar) for App Store Connect.
# Usage: scripts/make_speaker_pack.sh [models_dir] [out.aar]
#   models_dir: where fetch_sherpa_models.sh installed the models (default App/NovaDrive/SherpaModels)
# Checks the model against scripts/sherpa/models.sha256 first and writes nothing on a mismatch.
# The `xcrun ba-package` step needs a Mac with Xcode 26; elsewhere it stops after the check (--check-only implied).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
models="${1:-$root/App/NovaDrive/SherpaModels}"
out="${2:-$root/build/speaker-campplus-v1.aar}"
line="$(grep '  speaker/' "$root/scripts/sherpa/models.sha256" || true)"
[ -n "$line" ] || { echo "make_speaker_pack: no speaker/ line in scripts/sherpa/models.sha256" >&2; exit 1; }
want="${line%%  *}"
file="${line#*  }"
src="$models/$file"
[ -f "$src" ] || { echo "make_speaker_pack: missing $src (run scripts/fetch_sherpa_models.sh)" >&2; exit 1; }
[ -f "$models/speaker/speaker.json" ] || { echo "make_speaker_pack: missing $models/speaker/speaker.json" >&2; exit 1; }
if command -v sha256sum >/dev/null; then got="$(sha256sum "$src" | cut -d' ' -f1)"; else got="$(shasum -a 256 "$src" | cut -d' ' -f1)"; fi
[ "$got" = "$want" ] || { echo "make_speaker_pack: sha256 mismatch for $file (got $got)" >&2; exit 1; }
echo "make_speaker_pack: $file sha256 ok"
if ! command -v xcrun >/dev/null || ! xcrun --find ba-package >/dev/null 2>&1; then
  echo "make_speaker_pack: xcrun ba-package not found (needs a Mac with Xcode 26); stopping after the check" >&2
  exit 2
fi
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$root/scripts/speaker_pack/Manifest.json" "$stage/"
mkdir -p "$stage/speaker"
cp "$src" "$models/speaker/speaker.json" "$stage/speaker/"
mkdir -p "$(dirname "$out")"
(cd "$stage" && xcrun ba-package Manifest.json -o "$out")
echo "make_speaker_pack: wrote $out — upload it in App Store Connect → the app → Background Assets"
