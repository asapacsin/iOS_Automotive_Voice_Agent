#!/usr/bin/env bash
# Downloads the bundled sherpa-onnx models (F-05a §12 ASR, F-08 §14 KWS) from pinned Hugging Face revisions,
# verifies them against scripts/sherpa/models.sha256 and installs them as <dest>/{asr,kws} with a manifest each.
# Usage: scripts/fetch_sherpa_models.sh [dest]   (default App/NovaDrive/SherpaModels)
# Env: SHERPA_SHA_FILE overrides the checksum file (used by scripts/sherpa/test_checksum_failure.sh).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:-$root/App/NovaDrive/SherpaModels}"
sha_file="${SHERPA_SHA_FILE:-$root/scripts/sherpa/models.sha256}"
hf="https://huggingface.co"

# ASR: streaming zipformer small CTC zh int8, 2025-04-01 (Apache-2.0).
asr_repo="csukuangfj/sherpa-onnx-streaming-zipformer-small-ctc-zh-int8-2025-04-01"
asr_rev="a5f60fe00dcfbaf68fcc1c6b5cf53061e144d6da"
# KWS: wenetspeech 3.3M 2024-01-01 (Apache-2.0); the onnx files are byte-identical to the official
# k2-fsa kws-models release (same sha256), mirrored on HF because github.com release assets are not reachable.
kws_repo="Jeryuk/kws-zipformer-wenetspeech-3.3M-MNN"
kws_rev="df5d5e80a73b139d19217c46a9c72b6508c98b37"
kws_dir="kws-zipformer-wenetspeech-3.3M-MNN"
kws_enc="encoder-epoch-12-avg-2-chunk-16-left-64.onnx"
kws_dec="decoder-epoch-12-avg-2-chunk-16-left-64.onnx"
kws_join="joiner-epoch-12-avg-2-chunk-16-left-64.onnx"

[ -f "$sha_file" ] || { echo "fetch_sherpa_models: checksum file not found: $sha_file" >&2; exit 1; }
staging="$(mktemp -d "${TMPDIR:-/tmp}/sherpa-models.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/asr" "$staging/kws"

fetch() { # url out
  echo "fetch: $1"
  curl --fail --location --retry 3 --silent --show-error --output "$2" "$1"
}
fetch "$hf/$asr_repo/resolve/$asr_rev/model.int8.onnx" "$staging/asr/model.int8.onnx"
fetch "$hf/$asr_repo/resolve/$asr_rev/tokens.txt" "$staging/asr/tokens.txt"
for f in "$kws_enc" "$kws_dec" "$kws_join" tokens.txt; do
  fetch "$hf/$kws_repo/resolve/$kws_rev/$kws_dir/$f" "$staging/kws/$f"
done

# Every downloaded file must be listed, and every listed file must match.
listed="$(awk '{print $2}' "$sha_file" | sort)"
present="$(cd "$staging" && find asr kws -type f | sort)"
if [ "$listed" != "$present" ]; then
  echo "fetch_sherpa_models: $sha_file does not list exactly the downloaded files" >&2
  diff <(echo "$listed") <(echo "$present") >&2 || true
  exit 1
fi
if ! (cd "$staging" && sha256sum --check --strict --quiet "$sha_file"); then
  echo "fetch_sherpa_models: CHECKSUM MISMATCH against $sha_file; nothing installed" >&2
  exit 1
fi

cat > "$staging/asr/asr.json" <<JSON
{"name": "zipformer-small-ctc-zh-int8-2025-04-01", "type": "ctc", "model": "model.int8.onnx", "tokens": "tokens.txt"}
JSON
cat > "$staging/kws/kws.json" <<JSON
{"name": "kws-zipformer-wenetspeech-3.3M-2024-01-01", "type": "transducer", "encoder": "$kws_enc", "decoder": "$kws_dec", "joiner": "$kws_join", "tokens": "tokens.txt"}
JSON

mkdir -p "$dest"
rm -rf "$dest/asr" "$dest/kws"
cp -R "$staging/asr" "$staging/kws" "$dest/"
echo "installed into $dest ($(du -sm "$dest" | cut -f1) MB)"
