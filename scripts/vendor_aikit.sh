#!/usr/bin/env bash
# Installs the iFlytek AIKit wake SDK (licensed, device-only) into App/Vendor/AIKit/, which git ignores.
# Usage: scripts/vendor_aikit.sh <ios_ivw_e867a88f2_v1.0.13_v2.2.15-rc6.zip>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
zip="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unzip -q "$zip" -d "$tmp"
sdk="$(find "$tmp" -type d -name AIKITSDK -not -path '*__MACOSX*' | head -n 1)"
[ -n "$sdk" ] || { echo "no AIKITSDK folder in $zip" >&2; exit 1; }
dest="$root/App/Vendor/AIKit"
rm -rf "$dest"
mkdir -p "$dest"
cp -R "$sdk/COMMON/AIKIT.framework" "$sdk"/IVW/*.framework "$sdk/AEEResource.bundle" "$dest/"
echo "AIKit installed in $dest:"
ls "$dest"
