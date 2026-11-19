#!/usr/bin/env python3
"""F-09b §13 item 8: a tool result never carries a sentence for her to read out.

Scans Swift files in Packages/*/Sources and App for the script phrases. Until the end of stage 3 (T-031n) it
reports without failing; `--strict` makes findings fail (T-031n turns it on in run_static.sh).

`--root DIR` checks another tree (used by the gate self-tests).
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PHRASES = ["只说一句：", "只说这一句", "请如实说：", "请用户换个说法", "换个说法"]
# Item 7 allow-list: (path relative to the root, a substring of the allowed line). Empty at stage 1: none of the
# item 7 lines carries a script phrase.
ALLOW: list[tuple[str, str]] = []


def findings(root: pathlib.Path) -> list[str]:
    files = sorted(root.glob("Packages/*/Sources/**/*.swift")) + sorted(root.glob("App/**/*.swift"))
    out = []
    for path in files:
        rel = path.relative_to(root).as_posix()
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            phrase = next((p for p in PHRASES if p in line), None)
            if phrase is None or any(rel == a and s in line for a, s in ALLOW):
                continue
            out.append(f"{rel}:{number}: {phrase}")
    return out


def main(argv: list[str]) -> int:
    root = ROOT
    strict = "--strict" in argv
    if "--root" in argv:
        root = pathlib.Path(argv[argv.index("--root") + 1]).resolve()
    found = findings(root)
    for line in found:
        print(f"check_scripts: {line}")
    mode = "strict" if strict else "report-only"
    print(f"check_scripts: {len(found)} finding(s) ({mode})")
    return 1 if strict and found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
