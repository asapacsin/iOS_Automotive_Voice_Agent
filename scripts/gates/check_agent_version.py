#!/usr/bin/env python3
"""F-09b §15 item 5 (T-031y): specs/contracts/agent-versions.md is in order and every bump follows item 4.

Rows newest first; each has a note and a spec section; each has agent-setup-parts/<version>.json whose setupHash
equals the row; and the kind of change from the previous (older) version's parts matches the version bump:
major = a tool or tool parameter added/removed, a whole base part (【…】 section) rewritten, or the model changed;
minor = any other base, tool or note text change; patch = only `tuning.*` parts changed.
"""
import difflib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
REGISTRY = "specs/contracts/agent-versions.md"
PARTS = "specs/contracts/agent-setup-parts"
REWRITE = 0.5  # a 【…】 section kept under half its text counts as rewritten


def rows(text: str) -> list[dict]:
    out = []
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 6 and re.fullmatch(r"\d+\.\d+\.\d+", cells[0]):
            out.append({"version": cells[0], "hash": cells[1], "note": cells[4], "spec": cells[5]})
    return out


def sections(text: str) -> dict:
    found = re.findall(r"(【[^】]+】)([^【]*)", text)
    return {name: body for name, body in found}


def params(schema: str) -> set:
    try:
        return set((json.loads(schema).get("properties") or {}).keys())
    except (ValueError, AttributeError):
        return set()


def kind(old: dict, new: dict) -> str | None:
    """The bump `new` needs over `old` (parts name → text), or None when nothing changed."""
    tools = lambda parts: {n.split(".")[2] for n in parts if n.startswith("tool.")}
    if old.get("model") != new.get("model") or tools(old) != tools(new):
        return "major"
    for name in set(old) & set(new):
        if name.endswith(".schema") and params(old[name]) != params(new[name]):
            return "major"
        if name.startswith("base."):
            a, b = sections(old[name]), sections(new[name])
            if set(a) != set(b):
                return "major"
            if any(difflib.SequenceMatcher(None, a[s], b[s]).ratio() < REWRITE for s in a):
                return "major"
    changed = {n for n in set(old) | set(new) if old.get(n) != new.get(n)}
    if not changed:
        return None
    return "patch" if all(n.startswith("tuning.") for n in changed) else "minor"


def bump(older: str, newer: str) -> str | None:
    a, b = [tuple(int(x) for x in v.split(".")) for v in (older, newer)]
    if b[0] == a[0] + 1 and b[1:] == (0, 0):
        return "major"
    if b[0] == a[0] and b[1] == a[1] + 1 and b[2] == 0:
        return "minor"
    if b[:2] == a[:2] and b[2] == a[2] + 1:
        return "patch"
    return None


def problems(root: pathlib.Path = ROOT) -> list[str]:
    regs = rows((root / REGISTRY).read_text(encoding="utf-8"))
    if not regs:
        return [f"{REGISTRY}: no version rows"]
    out, parts = [], {}
    for r in regs:
        if not r["note"] or not r["spec"]:
            out.append(f"{r['version']}: a row needs a note and a spec section")
        path = root / PARTS / f"{r['version']}.json"
        if not path.exists():
            out.append(f"{r['version']}: {PARTS}/{r['version']}.json missing")
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("setupHash") != r["hash"]:
            out.append(f"{r['version']}: row hash {r['hash']} != parts setupHash {data.get('setupHash')}")
        parts[r["version"]] = data.get("parts", {})
    for newer, older in zip(regs, regs[1:]):
        b = bump(older["version"], newer["version"])
        if b is None:
            out.append(f"{newer['version']}: not the next major, minor or patch after {older['version']} (rows newest first)")
            continue
        if newer["version"] in parts and older["version"] in parts:
            need = kind(parts[older["version"]], parts[newer["version"]])
            if need is None:
                out.append(f"{newer['version']}: nothing changed since {older['version']}")
            elif need != b:
                out.append(f"{newer['version']}: the change needs a {need} bump, row is {b} (F-09b §15 item 4)")
    return out


def main(root: pathlib.Path = ROOT) -> int:
    found = problems(root)
    for p in found:
        print(f"check_agent_version: {p}")
    if not found:
        print("check_agent_version: OK")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
