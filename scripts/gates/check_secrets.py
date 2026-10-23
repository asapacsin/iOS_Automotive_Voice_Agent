#!/usr/bin/env python3
"""secrets gate (I-7): no key material in source, xcconfig, plist or workflow files."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
NAME = r"(?:api[_-]?key|secret|token|subscription[_-]?key|app[_-]?id|access[_-]?key)"
PATTERNS = {
    "google api key": re.compile(r"AIza[0-9A-Za-z_\-]{35}"),
    "private key block": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "bearer-style token": re.compile(r"\b(?:sk|bce)-[A-Za-z0-9]{20,}"),
    # Swift, JSON, YAML: name (quoted or not) then a quoted value.
    "assigned secret literal": re.compile(
        rf"(?i)[\"']?\w*{NAME}\w*[\"']?\s*[:=]\s*[\"'][A-Za-z0-9_\-]{{16,}}[\"']"),
    # xcconfig and .env: unquoted value. `$(AMAP_API_KEY)` references do not match.
    "unquoted secret assignment": re.compile(
        rf"(?im)^\s*\w*{NAME}\w*\s*=\s*[A-Za-z0-9_\-]{{16,}}\s*$"),
    "plist secret value": re.compile(
        rf"(?is)<key>[^<]*{NAME}[^<]*</key>\s*<string>[A-Za-z0-9_\-]{{16,}}</string>"),
    "secret http header": re.compile(
        r"(?i)\b(?:ocp-apim-subscription-key|x-goog-api-key|authorization)\s*:\s*(?:bearer\s+)?"
        r"[A-Za-z0-9_\-.]{16,}"),
}
SUFFIXES = {".swift", ".plist", ".xcconfig", ".json", ".jsonl", ".yml", ".yaml", ".entitlements",
            ".strings", ".env", ".har"}
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
