#!/usr/bin/env python3
"""imports gate: each framework has exactly one owner package (specs/ios-architecture.md §3.2)."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
# One statement (code is split on newlines and `;`). Attributes may take arguments: `@_spi(X) import M`.
# Swift 6 access levels (`public import M`) and backticked names (import `M`) count too.
IMPORT = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s*)*"
                    r"(?:(?:public|package|internal|fileprivate|private|open)\s+)?import\s+"
                    r"(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?`?([A-Za-z_][A-Za-z0-9_]*)`?")

# Framework -> packages (or "App") allowed to import it.
OWNERS = {
    "AMapNaviKit": {"NovaNavAmap"}, "AMapFoundationKit": {"NovaNavAmap"}, "MAMapKit": {"NovaNavAmap"},
    "iflyMSC": {"NovaWakeIflytek"},
    # sherpa-onnx C API module (c-api.h over the sherpa-onnx/onnxruntime xcframeworks), F-05a §12 item 4.
    "CSherpaOnnx": {"NovaAsrSherpa"},
    # AIKit ships device-only frameworks (no simulator slice), so it links into the app's device build
    # only; App/NovaDrive/Wake/AIKitWakeEngine.swift is its single importer.
    "AIKIT": {"App"}, "ef7d69542_v1009_aee": {"App"},
    "AVFAudio": {"NovaAudio"}, "SoundAnalysis": {"NovaAudio"},
    "AVFoundation": {"NovaPlatform"},
    "CoreLocation": {"NovaPlatform"}, "Network": {"NovaPlatform"}, "Contacts": {"NovaPlatform"}, "MusicKit": {"NovaPlatform"},
    "Security": {"NovaServices"},
    "UIKit": {"App", "NovaNavAmap"}, "SwiftUI": {"App", "NovaNavAmap"},
    "CarPlay": {"App"},
}
# Symbols (not modules) with one owner package.
# `session.webSocketTask(with:)` (or a reference to it) makes one without naming the type.
SYMBOL_OWNERS = {r"\bURLSessionWebSocketTask\b": {"NovaRealtime"}, r"\.\s*`?webSocketTask\b|\bwebSocketTask\s*\(": {"NovaRealtime"}}
CORE_ALLOWED = {"Foundation", "Synchronization", "NovaKit", "NovaPorts", "NovaVoice", "NovaTools",
                "NovaNav", "NovaAgent", "Testing", "XCTest"}


def owner_of(path: pathlib.Path, root: pathlib.Path) -> str:
    parts = path.relative_to(root).parts
    if parts[0] == "Packages":
        return parts[1]
    if parts[:2] == ("App", "NovaDriveTests"):
        return "NovaPlatform"  # NovaPlatform adapter tests (iOS-only package, so hosted in the app's test bundle).
    return parts[0]


def code_of(text: str) -> str:
    """Source with comments and string literals blanked, scanned left to right so `"http://x"` does not
    start a comment and a `/*` inside a string does not hide the code after it. Newlines are kept."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            depth, i = 1, i + 2  # Swift block comments nest.
            while i < n and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    out.append("\n" if text[i] == "\n" else "")
                    i += 1
            out.append(" ")
        elif (m := re.compile(r'(#*)("""|")').match(text, i)) and (m.group(1) or text[i] == '"'):
            hashes, quote = m.group(1), m.group(2)
            close, i = quote + hashes, m.end()
            while i < n and not text.startswith(close, i):
                if text[i] == "\\" and not hashes:
                    i += 1
                if i < n and text[i] == "\n":
                    out.append("\n")
                i += 1
            i += len(close)
            out.append('""')
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def imports_in(code: str) -> list[str]:
    statements = (part for line in code.splitlines() for part in line.split(";"))
    return [m.group(1) for m in map(IMPORT.match, statements) if m]


def main(argv: list[str]) -> int:
    root = pathlib.Path(argv[0]).resolve() if argv else ROOT
    failures = []
    files = [p for d in ("Packages", "App") for p in (root / d).rglob("*.swift")
             if ".build" not in p.parts and p.name != "Package.swift"]
    for path in files:
        owner = owner_of(path, root)
        code = code_of(path.read_text(encoding="utf-8"))
        rel = path.relative_to(root)
        for symbol, owners in SYMBOL_OWNERS.items():
            if re.search(symbol, code) and owner not in owners:
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
    sys.exit(main(sys.argv[1:]))
