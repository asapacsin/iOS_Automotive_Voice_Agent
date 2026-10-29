#!/usr/bin/env python3
"""Checks specs/open-questions.md: every OQ-IOS row has a known status, none is OPEN, answers are non-empty."""
import re
import sys
from pathlib import Path

STATUSES = ("ANSWERED", "PARTIAL", "DEVICE_SPIKE", "OWNER")


def check(text: str) -> list[str]:
    errors, seen = [], 0
    for line in text.splitlines():
        m = re.match(r"\|\s*(OQ-IOS-\d+)\s*\|", line)
        if not m:
            continue
        seen += 1
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5:
            errors.append(f"{m.group(1)}: malformed row")
            continue
        status, answer = cells[3], cells[4]
        if "OPEN" in status.split() or not status.startswith(STATUSES):
            errors.append(f"{m.group(1)}: status '{status}' not in {STATUSES}")
        if not answer:
            errors.append(f"{m.group(1)}: empty answer")
    if seen == 0:
        errors.append("no OQ-IOS rows found")
    return errors


def main() -> int:
    path = Path(__file__).resolve().parent.parent / "specs" / "open-questions.md"
    errors = check(path.read_text(encoding="utf-8"))
    for e in errors:
        print(f"ios-spec-check: {e}")
    print("ios-spec-check: " + ("FAIL" if errors else "PASS"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
