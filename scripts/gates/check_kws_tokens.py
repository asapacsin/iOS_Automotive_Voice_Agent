#!/usr/bin/env python3
"""F-08 §14: every token in StopPhrases.all must be in the bundled KWS model's tokens (scripts/sherpa/kws-tokens.txt)."""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
swift = (root / "Packages/NovaCore/Sources/NovaVoice/Lifecycle/StopPhrases.swift").read_text(encoding="utf-8")
vocab = {line.split()[0] for line in (root / "scripts/sherpa/kws-tokens.txt").read_text(encoding="utf-8").splitlines() if line.strip()}
phrases = re.findall(r'Phrase\(text:\s*"([^"]+)",\s*tokens:\s*\[([^\]]*)\]\)', swift)
if not phrases:
    sys.exit("check_kws_tokens: no StopPhrases found (parser out of date?)")
bad = [(t, tok) for t, toks in phrases for tok in re.findall(r'"([^"]+)"', toks) if tok not in vocab]
for t, tok in bad:
    print(f"check_kws_tokens: {t}: token {tok!r} not in scripts/sherpa/kws-tokens.txt")
if bad:
    sys.exit(1)
print(f"check_kws_tokens: {len(phrases)} stop phrases, all tokens in KWS vocabulary")
