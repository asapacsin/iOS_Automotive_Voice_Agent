#!/usr/bin/env python3
"""F-12 §21 item 4 (T-031u): every record format up to `ConversationRecord.formatVersion` has a row in
specs/contracts/record-format.md, and every format from 1 up has its fixture file."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = "Packages/NovaCore/Sources/NovaAgent/Record/ConversationRecord.swift"
NOTES = "specs/contracts/record-format.md"
FIXTURES = "Packages/NovaCore/Tests/NovaAgentTests/Fixtures"


def problems(root: pathlib.Path = ROOT) -> list[str]:
    src = (root / SOURCE).read_text(encoding="utf-8")
    m = re.search(r"static let formatVersion = (\d+)", src)
    if not m:
        return [f"{SOURCE}: no `static let formatVersion = <n>`"]
    version = int(m.group(1))
    notes = (root / NOTES).read_text(encoding="utf-8") if (root / NOTES).exists() else ""
    rows = {int(n) for n in re.findall(r"^\|\s*(\d+)\s*\|", notes, re.M)}
    out = [f"{NOTES}: format {n} has no row" for n in range(0, version + 1) if n not in rows]
    out += [f"{FIXTURES}/record-format-{n}.txt missing" for n in range(1, version + 1)
            if not (root / FIXTURES / f"record-format-{n}.txt").exists()]
    return out


def main(root: pathlib.Path = ROOT) -> int:
    found = problems(root)
    for p in found:
        print(f"check_record_format: {p} (F-12 §21 item 4)")
    if not found:
        print("check_record_format: OK")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
