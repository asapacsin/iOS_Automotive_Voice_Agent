#!/usr/bin/env python3
"""F-12 §21 item 6 (T-031u): one reader per record format; every reader gives the same rows.

Row: session (file name without .txt), turn (the `turn=<n>` on the line, or ""), ms, kind, fields,
legacy ("true" for format 0), agentVersion, agentHash, model (F-09b §15 item 7; "" before format 2), setup
("unregistered" when the agentHash is not a session hash of its agentVersion in specs/contracts/agent-setup-parts/). Usage: read.py <record.txt> [...] prints CSV rows. A format with no reader raises
UnknownFormat; it is never parsed by guessing.
"""
import csv
import json
import pathlib
import re
import sys

FIELDS = ["session", "turn", "ms", "kind", "fields", "legacy", "agentVersion", "agentHash", "model", "setup"]
PARTS_DIR = pathlib.Path(__file__).resolve().parents[2] / "specs" / "contracts" / "agent-setup-parts"
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


def agent_fields(lines: list[str], parts_dir: pathlib.Path = PARTS_DIR) -> dict:
    """The format-2 header's agent lines and whether the hash is a registered session hash of that version."""
    head = {}
    for line in lines[:12]:
        key, _, value = line.partition(" ")
        if key in ("agentVersion", "agentHash", "model"):
            head[key] = value
    out = {"agentVersion": head.get("agentVersion", ""), "agentHash": head.get("agentHash", ""),
           "model": head.get("model", ""), "setup": ""}
    if out["agentVersion"]:
        path = parts_dir / f"{out['agentVersion']}.json"
        sessions = json.loads(path.read_text(encoding="utf-8")).get("sessions", {}) if path.exists() else {}
        out["setup"] = "registered" if out["agentHash"] in sessions.values() else "unregistered"
    return out


def _events(session: str, lines: list[str], legacy: bool, agent: dict | None = None) -> list[dict]:
    agent = agent or {"agentVersion": "", "agentHash": "", "model": "", "setup": ""}
    rows = []
    for line in lines:
        m = EVENT.match(line)
        if not m:
            continue  # header lines and `dropped=<n>`
        t = TURN.search(m.group(3))
        rows.append({"session": session, "turn": t.group(1) if t else "", "ms": int(m.group(1)), "kind": m.group(2),
                     "fields": m.group(3), "legacy": "true" if legacy else "false", **agent})
    return rows


def read_format_0(session: str, lines: list[str]) -> list[dict]:
    """Best effort: everything written before `recordFormat` existed."""
    return _events(session, lines, legacy=True)


def read_format_1(session: str, lines: list[str]) -> list[dict]:
    return _events(session, lines[1:], legacy=False)


def read_format_2(session: str, lines: list[str]) -> list[dict]:
    return _events(session, lines[1:], legacy=False, agent=agent_fields(lines))


def read_format_3(session: str, lines: list[str]) -> list[dict]:
    """F-09b §16 item 9 (T-031z): as format 2, plus `screen <key>=<on|off> ... musicVolume=<n>` event lines."""
    return read_format_2(session, lines)


SEARCH_BODY_KINDS = ("search-request", "search-response")


def _join_search_bodies(lines: list[str]) -> tuple[list[str], set[int]]:
    """F-18 §34 item 4 (T-046w), best effort for format 4 and before: a raw search body ran over several lines. A line
    with no leading time after a `search-request` or `search-response` line belongs to that entry's body. Returns the
    joined lines and the indexes (in the joined list) of the entries that took such lines."""
    out: list[str] = []
    joined: set[int] = set()
    owner = None  # index in `out` of the open search entry
    for line in lines:
        m = EVENT.match(line)
        if m:
            owner = len(out) if m.group(2) in SEARCH_BODY_KINDS else None
            out.append(line)
        elif owner is not None:
            out[owner] += "\n" + line
            joined.add(owner)
        else:
            out.append(line)
    return out, joined


def read_format_4(session: str, lines: list[str]) -> list[dict]:
    """F-09b §17 item 7 (T-031zb): as format 3, plus `panel <key> <on|off> top=<panel|none>` event lines.
    F-18 §34 item 4: a search body written over several lines is joined back into its row, marked `legacy=true`."""
    joined_lines, joined = _join_search_bodies(lines[1:])
    rows = []
    agent = agent_fields(lines)
    for i, line in enumerate(joined_lines):
        m = re.match(r"^(\d+) (\S+) ?(.*)$", line, re.S)
        if not m:
            continue
        t = TURN.search(m.group(3))
        rows.append({"session": session, "turn": t.group(1) if t else "", "ms": int(m.group(1)), "kind": m.group(2),
                     "fields": m.group(3), "legacy": "true" if i in joined else "false", **agent})
    return rows


def unescape_body(text: str) -> str:
    """F-18 §34 item 1: the reverse of the record's escaping (`\\` `\n` `\r` `\t`)."""
    out, i = [], 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            n = text[i + 1]
            out.append({"n": "\n", "r": "\r", "t": "\t"}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def read_format_5(session: str, lines: list[str]) -> list[dict]:
    """F-18 §34 (T-046w): every entry is one line; the `body=` of `search-request` and `search-response` is escaped
    and is given back unescaped (the exact text), so `fields` of those rows may hold line breaks."""
    rows = _events(session, lines[1:], legacy=False, agent=agent_fields(lines))
    for r in rows:
        if r["kind"] in SEARCH_BODY_KINDS:
            head, sep, rest = r["fields"].partition(" body=")
            if sep:
                r["fields"] = head + sep + unescape_body(rest)
    return rows


def read_format_6(session: str, lines: list[str]) -> list[dict]:
    """F-15b §57 item 6, §56 item 6 (T-040zj, T-040zi): as format 5; the `screen` line has two more keys and a
    refused `set_trip_plan` writes `problems=<n>`, which the generic event reader already keeps as fields."""
    return read_format_5(session, lines)


def read_format_7(session: str, lines: list[str]) -> list[dict]:
    """F-04 §15 item 4 (T-004k): as format 6; the `screen` line has `backgroundWork` after `working`, and
    `panel backgroundWork on|off` lines, both kept as fields by the generic event reader."""
    return read_format_6(session, lines)


def read_format_8(session: str, lines: list[str]) -> list[dict]:
    """F-09b §19 items 5, 7 (T-031zd): as format 7; the `screen` line has `mapPin` and `show map` lines are added,
    both kept as fields by the generic event reader."""
    return read_format_7(session, lines)


def read_format_9(session: str, lines: list[str]) -> list[dict]:
    """F-15b §61 item 5 (T-040zn): as format 8; `trip set … saved=yes|no` (no check=, issues=, round=),
    `work step=trip_edit state=running|saved|refused`, `work step=trip_check`, `trip check-call …` and
    `trip asked …` lines, all kept as fields by the generic event reader."""
    return read_format_8(session, lines)


def read_format_10(session: str, lines: list[str]) -> list[dict]:
    """F-15b §62 items 9, 12 (T-040zo): as format 9; new `trip planner round=<n> ms= done=yes|no days= stops= model=`,
    `trip planner failed reason=http|timeout|json …`, `trip planner saved …`, `trip planner text plan=…|counts=…`
    (local record only), `work step=plan_trip state=…` and `handoff said tool=plan_trip ms=<n>` lines, all kept as
    fields by the generic event reader."""
    return read_format_9(session, lines)



def read_format_14(session: str, lines: list[str]) -> list[dict]:
    """F-18 §39 item 3 (amended 2026-11-25): as format 13; new `events extract failed status=<code> body=<300 chars>`
    line, kept as fields by the generic event reader."""
    return read_format_13(session, lines)


def read_format_13(session: str, lines: list[str]) -> list[dict]:
    """F-18 §39 item 8 (T-046zb): as format 12; the events lines are `events store … kinds=`, `events query`,
    `events extract`, `events search done`, `events queries cut=`, kept as fields by the generic event reader."""
    return read_format_12(session, lines)


def read_format_12(session: str, lines: list[str]) -> list[dict]:
    """F-18 §35 item 9 (T-046x): as format 11; new `events store hit|miss`, `events browse step=/done`, `events failed`
    lines (counts, codes and dates only), kept as fields by the generic event reader."""
    return read_format_11(session, lines)


def read_format_11(session: str, lines: list[str]) -> list[dict]:
    """F-09b §22 item 5 (T-031zg): as format 10; new `panel close tap <key>` lines (the driver tapped a panel's
    「×」), kept as fields by the generic event reader."""
    return read_format_10(session, lines)


def body(row: dict) -> str | None:
    """The `body=` text of a search row (everything after the first ` body=`), or None."""
    _, sep, rest = row["fields"].partition(" body=")
    return rest if sep else None


READERS = {0: read_format_0, 1: read_format_1, 2: read_format_2, 3: read_format_3, 4: read_format_4,
           5: read_format_5, 6: read_format_6, 7: read_format_7, 8: read_format_8, 9: read_format_9,
           10: read_format_10, 11: read_format_11, 12: read_format_12, 13: read_format_13, 14: read_format_14}


def read(path: pathlib.Path) -> list[dict]:
    # F-18 §34: entries end at a line feed only (splitlines would also split a body at U+2028, form feed, ...).
    # read_text would also turn a lone carriage return into a line break; a CRLF file keeps working.
    lines = [l.removesuffix("\r") for l in path.read_bytes().decode("utf-8", errors="replace").split("\n")]
    if lines and lines[-1] == "":
        lines.pop()
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
