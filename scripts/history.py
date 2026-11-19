#!/usr/bin/env python3
"""History archive for specs/STATUS.md and specs/work.json (specs/token-budget.md item 6, T-900f).

The model judges, this script applies and checks:
  history.py status [--hook]      sizes against the limits (--hook: one line only when over, for UserPromptSubmit)
  history.py candidates           compact table of finished items for the model to judge
  history.py apply DECISIONS.json {"T-013": {"do": "archive", "reason": "..."},
                                   "T-040v": {"do": "summarize", "notes": "short", "reason": "..."}, ...}
  history.py find ID              the archived item and its archived STATUS rows
  history.py check                gate: every stub has its archive entry, no id both live and archived,
                                  no STATUS row both live and archived
Rules apply enforces: only PASS / NOT_APPLICABLE items; a reason for each; a stub stays in work.json for every
archived id (frontier.py needs every dependency id); the full text goes to the archive, nothing is deleted;
a STATUS row moves only when every task id it names is archived.
"""
import datetime
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPECS = Path(os.environ.get("NOVA_HISTORY_SPECS", ROOT / "specs"))
WORK, WORK_ARCHIVE = SPECS / "work.json", SPECS / "work-archive.json"
STATUS, STATUS_ARCHIVE = SPECS / "STATUS.md", SPECS / "STATUS-archive.md"
LIMIT_KB = {STATUS: 75, WORK: 110}
FINISHED = {"PASS", "NOT_APPLICABLE"}
TASK_ID = re.compile(r"\b(?:T|H)-[0-9]+[a-z]*\b|\bG[0-9]+\b")
# T-071a-d, T-040v–x, T-042a/b, T-031n/o: the first id carries the letter, the second only a letter.
LETTER_RANGE = re.compile(r"\b([TH]-[0-9]+)([a-z])\s*([-–/])\s*([a-z])\b")


def task_ids(line, known=()):
    """Every task id a STATUS row names: plain ids, letter ranges expanded, and known ids such as H-keys."""
    ids = set(TASK_ID.findall(line))
    for base, a, sep, b in LETTER_RANGE.findall(line):
        letters = [chr(c) for c in range(ord(a), ord(b) + 1)] if sep != "/" else [a, b]
        ids.update(base + c for c in letters)
    ids.update(k for k in known if re.search(r"(?<![\w-])" + re.escape(k) + r"(?![\w-])", line))
    return ids
ARCHIVE_HEADER = ("# Implementation status archive\n\nRows moved from specs/STATUS.md by scripts/history.py "
                  "(specs/token-budget.md item 6). Same columns as STATUS.md.\n\n"
                  "| Date | Task | Result | Acceptance PASS (level) | NOT_VERIFIED / notes |\n|---|---|---|---|---|\n")


def load_json(path, empty):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else empty


def save_json(path, data):
    """Indented as before; in work.json each archived stub is one line (it is read for its id only)."""
    items = data.get("work") if isinstance(data, dict) else None
    if not isinstance(items, list) or not any(is_stub(x) for x in items):
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return
    head = {k: v for k, v in data.items() if k != "work"}
    lines = ["{"] + [f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}," for k, v in head.items()] + ['  "work": [']
    for n, x in enumerate(items):
        text = (json.dumps(x, ensure_ascii=False) if is_stub(x)
                else json.dumps(x, ensure_ascii=False, indent=2).replace("\n", "\n    "))
        lines.append("    " + text + ("," if n < len(items) - 1 else ""))
    lines += ["  ]", "}"]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def status_rows(text):
    """(index, line) for each table row with a date, from the live or archive file."""
    return [(i, l) for i, l in enumerate(text.splitlines()) if re.match(r"^\| 20\d\d-\d\d-\d\d \|", l)]


def is_stub(item):
    return bool(item.get("archived"))


def known_ids(work, archive=()):
    return {x["id"] for x in work} | {x["id"] for x in archive}


def cmd_status(hook):
    try:
        over = []
        for path, limit in LIMIT_KB.items():
            kb = path.stat().st_size / 1024
            over += [f"{path.name} {kb:.0f}/{limit} KB"] if kb > limit else []
            if not hook:
                print(f"{path.name}: {kb:.0f} KB (limit {limit})")
        if hook and over:
            print("history large: " + ", ".join(over) + ". When the current task allows, run scripts/history.py "
                  "candidates, judge keep/archive/summarize per item, then apply (specs/token-budget.md item 6).")
    except Exception:
        pass
    return 0


def cmd_candidates():
    work = load_json(WORK, {"work": []})["work"]
    known = known_ids(work)
    rows = [task_ids(l, known) and (l, task_ids(l, known)) for _, l in status_rows(STATUS.read_text(encoding="utf-8"))]
    rows = [r for r in rows if r]
    open_ids = {x["id"] for x in work if x["status"] not in FINISHED}
    dependents = {}
    for x in work:
        if x["id"] in open_ids:
            for d in x.get("depends_on", []):
                dependents.setdefault(d, []).append(x["id"])
    print("id | status | last STATUS date | open dependents | pending rows | last STATUS notes | KB | action")
    for x in work:
        if x["status"] not in FINISHED or is_stub(x):
            continue
        mine = [l for l, ids in rows if x["id"] in ids]
        date = mine[-1][2:12] if mine else "-"
        notes = mine[-1].rstrip(" |").rsplit("|", 1)[-1].strip()[:60] if mine else "-"
        pending = "yes" if mine and re.search(r"NOT_VERIFIED|NOT RUN|NOT_RUN|device|owner run", mine[-1].rsplit("|", 2)[-2]) else "-"
        size = len(json.dumps(x, ensure_ascii=False).encode()) / 1024
        print(f"{x['id']} | {x['status']} | {date} | {','.join(dependents.get(x['id'], [])) or '-'} | {pending} | "
              f"{notes} | {size:.1f} | {x['action'][:70]}")
    return 0


def cmd_apply(path):
    decisions = json.loads(Path(path).read_text(encoding="utf-8"))
    data = load_json(WORK, None)
    archive = load_json(WORK_ARCHIVE, {"schema_version": 1, "archived": []})
    by_id = {x["id"]: x for x in data["work"]}
    today = datetime.date.today().isoformat()
    errors, archived_now, summarized, kept = [], set(), 0, 0
    if not isinstance(decisions, dict):
        decisions, errors = {}, ["decisions must be an object {id: {do, reason}}"]
    for name, d in decisions.items():
        if not isinstance(d, dict):
            errors.append(f"{name}: decision must be an object with do and reason")
            continue
        item, do, reason = by_id.get(name), d.get("do"), str(d.get("reason", "")).strip()
        if item is None or is_stub(item):
            errors.append(f"{name}: not a live item")
        elif not reason:
            errors.append(f"{name}: reason required")
        elif do == "keep":
            kept += 1
        elif item["status"] not in FINISHED:
            errors.append(f"{name}: {item['status']} is open, only PASS / NOT_APPLICABLE move")
        elif do == "archive":
            archive["archived"].append({**item, "archived_on": today, "archive_reason": reason})
            stub = {"id": name, "owner": item["owner"], "status": item["status"], "action": "archived",
                    "depends_on": [], "archived": True, "evidence": ["work-archive.json"]}
            by_id[name].clear()
            by_id[name].update(stub)
            archived_now.add(name)
        elif do == "summarize" and str(d.get("notes", "")).strip():
            archive["archived"].append({**item, "archived_on": today, "archive_reason": "summarized: " + reason,
                                        "summarized": True})
            item["notes"] = str(d["notes"]).strip()
            summarized += 1
        else:
            errors.append(f"{name}: do must be keep, archive or summarize (summarize needs notes)")
    if errors:
        print("refused, nothing written:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 1
    stubs = {x["id"] for x in data["work"] if is_stub(x)}
    known = known_ids(data["work"], archive["archived"])
    lines = STATUS.read_text(encoding="utf-8").splitlines()
    moved = [(i, l) for i, l in status_rows("\n".join(lines))
             if (ids := task_ids(l, known)) and ids <= stubs]
    move_idx = {i for i, _ in moved}
    # Archives first: a crash in between leaves an id or row in both files, which check reports.
    save_json(WORK_ARCHIVE, archive)
    save_json(WORK, data)
    if moved:
        old = STATUS_ARCHIVE.read_text(encoding="utf-8") if STATUS_ARCHIVE.exists() else ARCHIVE_HEADER
        STATUS_ARCHIVE.write_text(old + "".join(l + "\n" for _, l in moved), encoding="utf-8")
        keep = [l for i, l in enumerate(lines) if i not in move_idx]
        note = "Older rows: specs/STATUS-archive.md (`scripts/history.py find <id>`)."
        if note not in keep:
            keep[3:3] = [note, ""]
        STATUS.write_text("\n".join(keep) + "\n", encoding="utf-8")
    print(f"archived {len(archived_now)}, summarized {summarized}, kept {kept}; STATUS rows moved {len(moved)}")
    return 0


def cmd_find(name):
    archive = load_json(WORK_ARCHIVE, {"archived": []})["archived"]
    hits = [x for x in archive if x["id"] == name]
    for x in hits:
        print(json.dumps(x, ensure_ascii=False, indent=2))
    if STATUS_ARCHIVE.exists():
        for _, l in status_rows(STATUS_ARCHIVE.read_text(encoding="utf-8")):
            if name in task_ids(l, {name}):
                print(l)
    return 0 if hits else 1


def cmd_check():
    work = load_json(WORK, {"work": []})["work"]
    archive = load_json(WORK_ARCHIVE, {"archived": []})["archived"]
    full = [x["id"] for x in archive if not x.get("summarized")]
    live = {x["id"] for x in work if not is_stub(x)}
    stubs = {x["id"] for x in work if is_stub(x)}
    errors = [f"{i}: stub without an archive entry" for i in sorted(stubs - set(full))]
    errors += [f"{i}: live in work.json and archived" for i in sorted(live & set(full))]
    errors += [f"{i}: archived without a stub in work.json" for i in sorted(set(full) - stubs - live)]
    errors += [f"{i}: archived more than once" for i in sorted({i for i in full if full.count(i) > 1})]
    if STATUS_ARCHIVE.exists():
        rows = {l for _, l in status_rows(STATUS.read_text(encoding="utf-8"))}
        known = known_ids(work, archive)
        for _, l in status_rows(STATUS_ARCHIVE.read_text(encoding="utf-8")):
            if l in rows:
                errors.append(f"STATUS row in both files: {l[:60]}")
            if task_ids(l, known) & live:
                errors.append(f"archived STATUS row names a live id: {l[:60]}")
    for e in errors:
        print("history check: " + e, file=sys.stderr)
    print("history check: " + ("FAIL" if errors else "PASS"))
    return 1 if errors else 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "status":
        return cmd_status("--hook" in rest)
    if cmd == "candidates":
        return cmd_candidates()
    if cmd == "apply" and rest:
        return cmd_apply(rest[0])
    if cmd == "find" and rest:
        return cmd_find(rest[0])
    if cmd == "check":
        return cmd_check()
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
