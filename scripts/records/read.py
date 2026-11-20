#!/usr/bin/env python3
"""F-12 §21 item 6 (T-031u): one reader per record format; every reader gives the same rows.

Row: session (file name without .txt), turn (the `turn=<n>` on the line, or ""), ms, kind, fields,
legacy ("true" for format 0). Usage: read.py <record.txt> [...] prints CSV rows. A format with no reader raises
UnknownFormat; it is never parsed by guessing.
"""
import csv
import pathlib
import re
import sys

FIELDS = ["session", "turn", "ms", "kind", "fields", "legacy"]
EVENT = re.compile(r"^(\d+) (\S+) ?(.*)$")
TURN = re.compile(r"\bturn=(\d+)\b")


class UnknownFormat(Exception):
    def __init__(self, n):
        super().__init__(f"unknown recordFormat {n}")
        self.format = n


def record_format(lines: list[str]) -> int:
    """The `recordFormat <n>` of line 1; 0 when the file has none."""
    if lines and lines[0].startswith("recordFormat "):
        try:
            return int(lines[0].split()[1])
        except (IndexError, ValueError):
            raise UnknownFormat(lines[0].split(maxsplit=1)[-1])
    return 0


def _events(session: str, lines: list[str], legacy: bool) -> list[dict]:
    rows = []
    for line in lines:
        m = EVENT.match(line)
        if not m:
            continue  # header lines and `dropped=<n>`
        t = TURN.search(m.group(3))
        rows.append({"session": session, "turn": t.group(1) if t else "", "ms": int(m.group(1)), "kind": m.group(2),
                     "fields": m.group(3), "legacy": "true" if legacy else "false"})
    return rows


def read_format_0(session: str, lines: list[str]) -> list[dict]:
    """Best effort: everything written before `recordFormat` existed."""
    return _events(session, lines, legacy=True)


def read_format_1(session: str, lines: list[str]) -> list[dict]:
    return _events(session, lines[1:], legacy=False)


READERS = {0: read_format_0, 1: read_format_1}


def read(path: pathlib.Path) -> list[dict]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    n = record_format(lines)
    if n not in READERS:
        raise UnknownFormat(n)
    return READERS[n](path.stem, lines)


def main(argv=None) -> int:
    paths = [pathlib.Path(p) for p in (sys.argv[1:] if argv is None else argv)]
    w = csv.DictWriter(sys.stdout, fieldnames=FIELDS)
    w.writeheader()
    status = 0
    for p in paths:
        try:
            w.writerows(read(p))
        except UnknownFormat as e:
            print(f"{p.name}: {e}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
