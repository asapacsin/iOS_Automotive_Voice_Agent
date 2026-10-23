#!/usr/bin/env python3
"""secrets gate (I-7): no key material in source, xcconfig, plist or workflow files."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATTERNS = {
    "google api key": re.compile(r"AIza[0-9A-Za-z_\-]{35}"),
    "private key block": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "bearer-style token": re.compile(r"\b(?:sk|bce)-[A-Za-z0-9]{20,}"),
    "assigned secret literal": re.compile(
        r"(?i)(api[_-]?key|secret|token|subscription[_-]?key)\s*[:=]\s*\"[A-Za-z0-9_\-]{16,}\""),
}
SUFFIXES = {".swift", ".plist", ".xcconfig", ".json", ".yml", ".yaml", ".entitlements", ".strings"}
SKIP_DIRS = {".build", ".git", "DerivedData", "specs"}


def main() -> int:
    hits = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in SUFFIXES or SKIP_DIRS & set(path.parts):
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for name, pattern in PATTERNS.items():
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                hits.append(f"{path.relative_to(ROOT)}:{line}: {name}")
    for hit in hits:
        print(f"SECRETS FAIL {hit}")
    print(f"secrets: {len(hits)} findings")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
