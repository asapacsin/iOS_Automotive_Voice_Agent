#!/usr/bin/env python3
"""Owner rule (2026-10-27): no macOS GitHub Actions runners, and no automatic triggers.

macOS minutes are billed 10x and used up the account's Actions allowance. Fails if any workflow uses a
macOS runner or starts on push / pull_request / schedule.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[2]
bad = []
for wf in sorted((root / ".github" / "workflows").glob("*.y*ml")):
    text = wf.read_text(encoding="utf-8")
    for n, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0]
        if re.search(r"runs-on:.*macos", code, re.I):
            bad.append(f"{wf.name}:{n}: macOS runner is forbidden")
        if re.match(r"\s*(push|pull_request|pull_request_target|schedule)\s*:", code):
            bad.append(f"{wf.name}:{n}: automatic trigger is forbidden (use workflow_dispatch)")
for b in bad:
    print("RUNNERS FAIL", b)
print(f"runners: {len(bad)} violations")
sys.exit(1 if bad else 0)
