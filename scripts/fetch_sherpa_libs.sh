#!/usr/bin/env bash
# Downloads the pinned sherpa-onnx iOS build (F-05a §12 item 4, F-08 §14 item 2) from a pinned Hugging Face revision,
# verifies it against scripts/sherpa/libs.sha256 and installs the xcframeworks into Packages/NovaAsrSherpa/Frameworks/
# (gitignored). The tarball bundles the onnxruntime xcframework it was built against (1.17.1), so that is used as is.
# Usage: scripts/fetch_sherpa_libs.sh            Env: SHERPA_LIBS_SHA_FILE overrides the checksum file.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sha_file="${SHERPA_LIBS_SHA_FILE:-$root/scripts/sherpa/libs.sha256}"
dest="$root/Packages/NovaAsrSherpa/Frameworks"
header="$root/Packages/NovaAsrSherpa/Sources/CSherpaOnnx/include/c-api.h"

version="v1.12.21"
tarball="sherpa-onnx-$version-ios-no-tts.tar.bz2"
repo="csukuangfj/sherpa-onnx-libs"
rev="da78432ea90a1fda33002e933825e3cbf3a5ac78"
url="https://huggingface.co/$repo/resolve/$rev/$tarball"

[ -f "$sha_file" ] || { echo "fetch_sherpa_libs: checksum file not found: $sha_file" >&2; exit 1; }
staging="$(mktemp -d "${TMPDIR:-/tmp}/sherpa-libs.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

echo "fetch: $url"
curl --fail --location --retry 3 --silent --show-error --output "$staging/$tarball" "$url"
if ! (cd "$staging" && sha256sum --check --strict --quiet "$sha_file"); then
  echo "fetch_sherpa_libs: CHECKSUM MISMATCH for $tarball against $sha_file; nothing installed" >&2
  exit 1
fi

mkdir "$staging/x"
tar -xjf "$staging/$tarball" -C "$staging/x"
build="$staging/x/build-ios-no-tts"
sherpa="$build/sherpa-onnx.xcframework"
ort="$build/ios-onnxruntime/1.17.1/onnxruntime.xcframework"
for d in "$sherpa" "$ort"; do
  [ -f "$d/Info.plist" ] || { echo "fetch_sherpa_libs: $d missing from $tarball" >&2; exit 1; }
done
# The Swift side compiles against the committed copy of c-api.h; it must match the library's header exactly.
if ! cmp -s "$sherpa/Headers/sherpa-onnx/c-api/c-api.h" "$header"; then
  echo "fetch_sherpa_libs: $header differs from the c-api.h in $tarball; update it with the library" >&2
  exit 1
fi

rm -rf "$dest"
mkdir -p "$dest"
cp -R "$sherpa" "$dest/sherpa-onnx.xcframework"
cp -R "$ort" "$dest/onnxruntime.xcframework"
echo "installed: $dest/{sherpa-onnx,onnxruntime}.xcframework (sherpa-onnx $version, onnxruntime 1.17.1)"
