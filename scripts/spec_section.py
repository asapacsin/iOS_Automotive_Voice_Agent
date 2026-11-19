#!/usr/bin/env python3
"""Print one section of a feature spec, or the list of its sections with line ranges.

Saves reading a whole spec file (trip-plan.md is ~165 KB) when a task needs one section.
The list is built from the headings each time, so it never goes stale.

  scripts/spec_section.py trip-plan          # sections with line ranges and sizes
  scripts/spec_section.py trip-plan 51       # §51 through the line before the next ## heading
  scripts/spec_section.py trip-plan 5.2      # a ### subsection
  scripts/spec_section.py --all              # every feature file with its size
"""
import re
import sys
from pathlib import Path

FEATURES = Path(__file__).resolve().parent.parent / "specs" / "features"
HEADING = re.compile(r"^(#{1,4}) (.*)$")
NUMBER = re.compile(r"^(\d+(?:\.\d+)*)[.\s]")


def spec_path(name: str) -> Path:
    path = FEATURES / (name if name.endswith(".md") else name + ".md")
    if not path.is_file():
        sys.exit(f"no spec {path.name} in specs/features (try --all)")
    return path


def headings(lines):
    """(line index, level, number or None, title) for each heading outside code fences."""
    out, fenced = [], False
    for i, line in enumerate(lines):
        if line.startswith("```"):
            fenced = not fenced
            continue
        m = None if fenced else HEADING.match(line)
        if m:
            n = NUMBER.match(m.group(2))
            out.append((i, len(m.group(1)), n.group(1) if n else None, m.group(2)))
    return out


def section_end(heads, k, total):
    level = heads[k][1]
    for i, lv, _, _ in heads[k + 1:]:
        if lv <= level:
            return i
    return total


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    if argv[0] == "--all":
        for p in sorted(FEATURES.glob("*.md")):
            print(f"{p.stat().st_size // 1024:>4} KB  {p.stem}")
        return 0
    lines = spec_path(argv[0]).read_text(encoding="utf-8").splitlines()
    heads = headings(lines)
    if len(argv) == 1:
        for k, (i, lv, num, title) in enumerate(heads):
            end = section_end(heads, k, len(lines))
            size = sum(len(l.encode()) + 1 for l in lines[i:end]) // 1024
            print(f"{i + 1:>5}-{end:<5} {size:>3} KB  {'  ' * (lv - 1)}{title[:90]}")
        return 0
    want = argv[1].lstrip("§")
    for k, (i, lv, num, _) in enumerate(heads):
        if num == want:
            end = section_end(heads, k, len(lines))
            print(f"[{argv[0]} lines {i + 1}-{end}]")
            print("\n".join(lines[i:end]))
            return 0
    sys.exit(f"no section {want} in {argv[0]} (run without a section to list them)")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
