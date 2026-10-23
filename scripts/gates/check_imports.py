#!/usr/bin/env python3
"""imports gate: each framework has exactly one owner package (specs/ios-architecture.md §3.2)."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
# One statement (code is split on newlines and `;`). Attributes may take arguments: `@_spi(X) import M`.
IMPORT = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s*)*import\s+"
                    r"(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")

# Framework -> packages (or "App") allowed to import it.
OWNERS = {
    "AMapNaviKit": {"NovaNavAmap"}, "AMapFoundationKit": {"NovaNavAmap"}, "MAMapKit": {"NovaNavAmap"},
    "iflyMSC": {"NovaWakeIflytek"},
    "AVFAudio": {"NovaAudio"},
    "AVFoundation": {"NovaPlatform"},
    "CoreLocation": {"NovaPlatform"}, "Contacts": {"NovaPlatform"}, "MusicKit": {"NovaPlatform"},
    "Security": {"NovaServices"},
    "UIKit": {"App", "NovaNavAmap"}, "SwiftUI": {"App", "NovaNavAmap"},
    "CarPlay": {"App"},
}
# Symbols (not modules) with one owner package.
SYMBOL_OWNERS = {"URLSessionWebSocketTask": {"NovaRealtime"}}
CORE_ALLOWED = {"Foundation", "Synchronization", "NovaKit", "NovaPorts", "NovaVoice", "NovaTools",
                "NovaNav", "NovaAgent", "Testing", "XCTest"}


def owner_of(path: pathlib.Path) -> str:
    parts = path.relative_to(ROOT).parts
    if parts[0] == "Packages":
        return parts[1]
    return parts[0]


def code_of(text: str) -> str:
    return LINE_COMMENT.sub("", BLOCK_COMMENT.sub(" ", text))


def imports_in(code: str) -> list[str]:
    statements = (part for line in code.splitlines() for part in line.split(";"))
    return [m.group(1) for m in map(IMPORT.match, statements) if m]


def main() -> int:
    failures = []
    files = [p for d in ("Packages", "App") for p in (ROOT / d).rglob("*.swift")
             if ".build" not in p.parts and p.name != "Package.swift"]
    for path in files:
        owner = owner_of(path)
        code = code_of(path.read_text(encoding="utf-8"))
        rel = path.relative_to(ROOT)
        for symbol, owners in SYMBOL_OWNERS.items():
            if re.search(rf"\b{symbol}\b", code) and owner not in owners:
                failures.append(f"{rel}: {symbol} is owned by {sorted(owners)}, not {owner}")
        for module in imports_in(code):
            if owner == "NovaCore" and module not in CORE_ALLOWED:
                failures.append(f"{rel}: NovaCore may not import {module}")
            elif module in OWNERS and owner not in OWNERS[module]:
                failures.append(f"{rel}: {module} is owned by {sorted(OWNERS[module])}, not {owner}")
    for failure in failures:
        print(f"IMPORTS FAIL {failure}")
    print(f"imports: {len(files)} files, {len(failures)} violations")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
