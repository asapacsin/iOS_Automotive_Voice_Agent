#!/usr/bin/env python3
"""F-08 §14, F-01 §14 item 2: every token of StopPhrases.all and of the WakePhrase lines must be in the bundled KWS
model's tokens (scripts/sherpa/kws-tokens.txt).

`--root DIR` checks another tree (used by the gate self-tests).
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PHRASE = re.compile(r'Phrase\(text:\s*"([^"]+)",\s*tokens:\s*\[([^\]]*)\]\)')
SOURCES = {
    "stop phrases": "Packages/NovaCore/Sources/NovaVoice/Lifecycle/StopPhrases.swift",
    "wake phrase lines": "Packages/NovaCore/Sources/NovaVoice/Wake/WakePhrase.swift",
}


def main(argv: list[str]) -> int:
    root = ROOT
    if argv[:1] == ["--root"]:
        root = pathlib.Path(argv[1]).resolve()
    vocab = {line.split()[0] for line in (root / "scripts/sherpa/kws-tokens.txt").read_text(encoding="utf-8").splitlines()
             if line.strip()}
    failed = False
    counts = []
    for what, rel in SOURCES.items():
        phrases = PHRASE.findall((root / rel).read_text(encoding="utf-8"))
        if not phrases:
            print(f"check_kws_tokens: no {what} found in {rel} (parser out of date?)")
            failed = True
            continue
        for text, toks in phrases:
            for tok in re.findall(r'"([^"]+)"', toks):
                if tok not in vocab:
                    print(f"check_kws_tokens: {what}: {text}: token {tok!r} not in scripts/sherpa/kws-tokens.txt")
                    failed = True
        counts.append(f"{len(phrases)} {what}")
    if failed:
        return 1
    print(f"check_kws_tokens: {', '.join(counts)}, all tokens in KWS vocabulary")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
