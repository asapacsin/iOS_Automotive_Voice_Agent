#!/usr/bin/env python3
"""F-09b §13 item 8: a tool result never carries a sentence for her to read out.

Scans Swift files in Packages/*/Sources and App for the script phrases. `--strict` makes findings fail; run_static.sh runs it strict from the end of stage 3 (T-031n).

`--root DIR` checks another tree (used by the gate self-tests).
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PHRASES = ["只说一句：", "只说这一句", "请如实说：", "请用户换个说法", "换个说法"]
# Item 7 allow-list: (path relative to the root, a substring of the allowed line).
ALLOW: list[tuple[str, str]] = [
    # Item 7: the tone confirmation (F-21 §17 item 3, T-034d) stays fixed; it must not promise a different voice.
    ("Packages/NovaCore/Sources/NovaAgent/Persona/SpeakingStyle.swift", 'let reply = "只说这一句：" + style.confirmation'),
    # The catalog's working line (F-15b §50 item 5) is a tool description, not a tool result; its wording is
    # F-15b's, so it is kept until that spec changes it (T-031n, recorded in STATUS).
    ("Packages/NovaCore/Sources/NovaTools/Dispatch/ToolCatalog.swift", "public static let tripWorkingLine = "),
]


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
