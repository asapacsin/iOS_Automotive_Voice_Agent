#!/usr/bin/env python3
"""spec-trace gate: every acceptance ID of a task packet is named by at least one test.

Usage: spec_trace.py F-04 W8 ...   (IDs as written in test names, e.g. @Test("F-04 ..."))
With no IDs it checks every ID listed in specs/trace-ids.txt (lines "T-011: F-03 F-24"), as CI does.
An ID counts only inside a @Test name and only as a whole token: F-1 is not satisfied by F-10.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
TEST_NAME = re.compile(r'@Test\(\s*"((?:[^"\\]|\\.)*)"')
REGISTRY = ROOT / "specs" / "trace-ids.txt"


def registered_ids() -> list[str]:
    ids = []
    for line in REGISTRY.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0]
        if ":" in line:
            ids += line.split(":", 1)[1].split()
    return ids


def main(ids: list[str]) -> int:
    if not ids:
        ids = registered_ids()
    names = [name for p in ROOT.rglob("*.swift") if "Tests" in p.parts and ".build" not in p.parts
             for name in TEST_NAME.findall(p.read_text(encoding="utf-8"))]
    missing = [i for i in ids
               if not any(re.search(rf"(?<![\w-]){re.escape(i)}(?![\w])", name) for name in names)]
    for i in missing:
        print(f"SPEC-TRACE FAIL no test names {i}")
    print(f"spec-trace: {len(ids)} ids, {len(missing)} missing")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
