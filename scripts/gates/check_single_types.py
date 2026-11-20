#!/usr/bin/env python3
"""F-09b §16 item 10 (T-031z): types that must have one definition across the Swift sources.

`NavigationPhase` lives in NovaKit/States.swift only; a second `enum NavigationPhase` anywhere fails (row 6).
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SINGLE = {"NavigationPhase": "Packages/NovaCore/Sources/NovaKit/States.swift"}
DIRS = ("Packages", "App")


def problems(root: pathlib.Path = ROOT) -> list[str]:
    out = []
    for name, home in SINGLE.items():
        pattern = re.compile(rf"^\s*(@\w+\s+)*((public|package|internal|fileprivate|private)\s+)?(indirect\s+)?(enum|struct|class|typealias)\s+{name}\b", re.M)
        found = sorted(str(p.relative_to(root)) for d in DIRS if (root / d).exists()
                       for p in (root / d).rglob("*.swift")
                       if "/.build/" not in str(p) and pattern.search(p.read_text(encoding="utf-8", errors="ignore")))
        if found != [home]:
            out.append(f"{name}: defined in {found or 'nowhere'}; only {home} (F-09b §16 item 10)")
    return out


def main() -> int:
    issues = problems()
    for issue in issues:
        print(f"check_single_types: {issue}")
    if issues:
        return 1
    print("check_single_types: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
