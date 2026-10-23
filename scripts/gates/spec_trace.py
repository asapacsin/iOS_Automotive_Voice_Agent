#!/usr/bin/env python3
"""spec-trace gate: every acceptance ID of a task packet is named by at least one test.

Usage: spec_trace.py F-04 W8 ...   (IDs as written in test names, e.g. @Test("F-04 ..."))
With no IDs it checks every ID listed in specs/trace-ids.txt (lines "T-011: F-03 F-24"), as CI does.
An ID counts only inside a @Test name and only as a whole token: F-1 is not satisfied by F-10.
A @Test inside a comment or string, or one with a `.disabled` trait, does not count.
`--root DIR` scans another tree (used by the gate self-tests).
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from check_imports import code_of  # noqa: E402  (same comment/string stripper as the imports gate)

ROOT = pathlib.Path(__file__).resolve().parents[2]
TEST_NAME = re.compile(r'@Test\(\s*"((?:[^"\\]|\\.)*)"')
# Balanced to one level of nested parentheses: @Test("x", .disabled("why"), .bug(id: 1)).
TEST_ATTR = re.compile(r'@Test\((?:[^()]|\([^()]*\))*\)', re.S)
REGISTRY = ROOT / "specs" / "trace-ids.txt"


def test_names(text: str) -> list[str]:
    """Names of enabled @Test attributes that are real code (not in a comment or string)."""
    names = []
    for attr in TEST_ATTR.finditer(text):
        if not _is_code(text, attr.start()):
            continue
        if re.search(r"\.disabled\b", attr.group(0)):
            continue
        names += TEST_NAME.findall(attr.group(0))
    return names


def _is_code(text: str, offset: int) -> bool:
    """True when `offset` is outside comments and string literals."""
    marker = "\x00"
    probe = text[:offset] + marker + text[offset:]
    return marker in code_of(probe)


def registered_ids(registry: pathlib.Path = REGISTRY) -> list[str]:
    ids = []
    for line in registry.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0]
        if ":" in line:
            ids += line.split(":", 1)[1].split()
    return ids


def main(argv: list[str]) -> int:
    root = ROOT
    if argv[:1] == ["--root"]:
        root, argv = pathlib.Path(argv[1]).resolve(), argv[2:]
    ids = argv or registered_ids(root / "specs" / "trace-ids.txt")
    names = [name for p in root.rglob("*.swift") if "Tests" in p.parts and ".build" not in p.parts
             for name in test_names(p.read_text(encoding="utf-8"))]
    missing = [i for i in ids
               if not any(re.search(rf"(?<![\w-]){re.escape(i)}(?![\w])", name) for name in names)]
    for i in missing:
        print(f"SPEC-TRACE FAIL no test names {i}")
    print(f"spec-trace: {len(ids)} ids, {len(missing)} missing")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
