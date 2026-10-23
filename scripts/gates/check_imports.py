#!/usr/bin/env python3
"""imports gate: each framework has exactly one owner package (specs/ios-architecture.md §3.2)."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
IMPORT = re.compile(r"^\s*(?:@\w+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)", re.M)

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
CORE_ALLOWED = {"Foundation", "Synchronization", "NovaKit", "NovaPorts", "NovaVoice", "NovaTools",
                "NovaNav", "NovaAgent", "Testing", "XCTest"}


def owner_of(path: pathlib.Path) -> str:
    parts = path.relative_to(ROOT).parts
    if parts[0] == "Packages":
        return parts[1]
    return parts[0]


def main() -> int:
    failures = []
    files = [p for d in ("Packages", "App") for p in (ROOT / d).rglob("*.swift")
             if ".build" not in p.parts and p.name != "Package.swift"]
    for path in files:
        owner = owner_of(path)
        for module in IMPORT.findall(path.read_text(encoding="utf-8")):
            rel = path.relative_to(ROOT)
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
