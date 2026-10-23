#!/usr/bin/env python3
"""spec-trace gate: every acceptance ID of a task packet is named by at least one test.

Usage: spec_trace.py F-04 W8 ...   (IDs as written in test names, e.g. @Test("F-04 ..."))
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main(ids: list[str]) -> int:
    tests = [p.read_text(encoding="utf-8") for p in ROOT.rglob("*.swift")
             if "Tests" in p.parts and ".build" not in p.parts]
    missing = [i for i in ids if not any(i in text for text in tests)]
    for i in missing:
        print(f"SPEC-TRACE FAIL no test names {i}")
    print(f"spec-trace: {len(ids)} ids, {len(missing)} missing")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
