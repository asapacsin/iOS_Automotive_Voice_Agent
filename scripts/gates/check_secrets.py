#!/usr/bin/env python3
"""secrets gate (I-7): no key material in source, xcconfig, plist, project or workflow files."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CREDENTIAL_KEYS = ROOT / "Packages" / "NovaCore" / "Sources" / "NovaPorts" / "Services.swift"


def credential_names() -> list[str]:
    """Raw values of `CredentialKey` (gemini_api_key, ...), so a new stored secret is scanned for at once."""
    text = CREDENTIAL_KEYS.read_text(encoding="utf-8") if CREDENTIAL_KEYS.exists() else ""
    body = re.search(r"enum CredentialKey\b[^{]*\{(.*?)\n\}", text, re.S)
    raw = re.findall(r'case\s+\w+\s*=\s*"([^"]+)"', body.group(1)) if body else []
    # Match both spellings: gemini_api_key and geminiApiKey / GEMINI_API_KEY (case-insensitive below).
    return sorted({re.escape(name) for name in raw} | {re.escape(name.replace("_", "")) for name in raw})


NAME = (r"(?:api[_-]?key|secret|token|subscription[_-]?key|app[_-]?id|access[_-]?key|_key|key_|"
        + "|".join(credential_names() or ["(?!)"]) + ")")
IDENT = rf"\w*{NAME}\w*"
VALUE = r"[A-Za-z0-9_\-+/.=]{16,}"
PATTERNS = {
    "google api key": re.compile(r"AIza[0-9A-Za-z_\-]{35}"),
    "private key block": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "bearer-style token": re.compile(r"\b(?:sk|bce)-[A-Za-z0-9]{20,}"),
    # Swift, JSON, YAML, pbxproj: name (quoted or not, optional Swift type annotation) then a quoted value.
    "assigned secret literal": re.compile(
        rf"(?i)[\"']?{IDENT}[\"']?\s*(?::\s*[\w.<>?!\[\]]+\s*)?[:=]\s*#*(?:\"\"\"\s*)?[\"']{VALUE}[\"']"),
    # xcconfig, .env, YAML: unquoted value, optional xcconfig condition `[sdk=iphoneos*]`, trailing
    # `//` or `#` comment. `$(AMAP_API_KEY)` and `${{ secrets.X }}` references do not match.
    "unquoted secret assignment": re.compile(
        rf"(?im)^\s*(?:export\s+|-\s+)?{IDENT}(?:\[[^\]\n]*\])*\s*[:=]\s*{VALUE}\s*(?:(?://|#).*)?$"),
    "plist secret value": re.compile(
        rf"(?is)<key>[^<]*{NAME}[^<]*</key>\s*<string>{VALUE}</string>"),
    # .xcscheme environment variables: <EnvironmentVariable key = "GEMINI_API_KEY" value = "...">.
    "xml attribute secret": re.compile(
        rf"(?is)\bkey\s*=\s*\"{IDENT}\"\s+value\s*=\s*\"{VALUE}\""),
    "secret http header": re.compile(
        r"(?i)\b(?:ocp-apim-subscription-key|x-goog-api-key|x-api-key|authorization)\s*:\s*(?:bearer\s+)?"
        r"[A-Za-z0-9_\-.]{16,}"),
    # HAR: {"name": "x-goog-api-key", "value": "..."} in either order; also query-string params.
    "har header or param": re.compile(
        rf"(?is)\"name\"\s*:\s*\"(?:ocp-apim-subscription-key|x-goog-api-key|x-api-key|authorization|key|"
        rf"{IDENT})\"\s*,\s*\"value\"\s*:\s*\"(?:bearer\s+)?{VALUE}\"|"
        rf"\"value\"\s*:\s*\"(?:bearer\s+)?{VALUE}\"\s*,\s*\"name\"\s*:\s*\"(?:ocp-apim-subscription-key|"
        rf"x-goog-api-key|x-api-key|authorization|key|{IDENT})\""),
    "secret url parameter": re.compile(rf"(?i)[?&](?:key|{IDENT})={VALUE}"),
}
UNCONDITIONAL = {"google api key", "private key block", "bearer-style token"}
SUFFIXES = {".swift", ".plist", ".xcconfig", ".json", ".jsonl", ".yml", ".yaml", ".entitlements",
            ".strings", ".env", ".har", ".xcscheme", ".pbxproj", ".xcworkspacedata", ".sh", ".py",
            ".md", ".txt", ".toml", ".cfg", ".ini"}
SKIP_DIRS = {".build", ".git", "DerivedData", "specs", "__pycache__"}
# Gate self-tests plant fake secrets on purpose.
SKIP_FILES = {pathlib.Path("scripts/gates/tests/test_gates.py")}


IDENTIFIER_VALUE = re.compile(r"[a-z]+(?:_[a-z]+)+|[A-Z]+(?:_[A-Z]+)+")


def is_identifier_only(text: str) -> bool:
    """`case amapWebKey = "amap_web_key"` names a key; it is not one. Real keys are not pure snake case."""
    values = [v for v in re.findall(VALUE, text) if len(v) >= 16]
    return bool(values) and all(IDENTIFIER_VALUE.fullmatch(v) for v in values[-1:])


def scanned(path: pathlib.Path, root: pathlib.Path) -> bool:
    rel = path.relative_to(root)
    if not path.is_file() or SKIP_DIRS & set(rel.parts) or rel in SKIP_FILES:
        return False
    # `.env`, `.env.local`, `prod.env`: dotfiles have no suffix to pathlib.
    return path.suffix in SUFFIXES or path.name == ".env" or path.name.startswith(".env.")


def scan(root: pathlib.Path) -> list[str]:
    hits = []
    for path in sorted(root.rglob("*")):
        if not scanned(path, root):
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for name, pattern in PATTERNS.items():
            for match in pattern.finditer(text):
                if name not in UNCONDITIONAL and is_identifier_only(match.group(0)):
                    continue
                line = text.count("\n", 0, match.start()) + 1
                hits.append(f"{path.relative_to(root)}:{line}: {name}")
    return hits


def main(argv: list[str]) -> int:
    root = pathlib.Path(argv[0]).resolve() if argv else ROOT
    hits = scan(root)
    for hit in hits:
        print(f"SECRETS FAIL {hit}")
    print(f"secrets: {len(hits)} findings")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
