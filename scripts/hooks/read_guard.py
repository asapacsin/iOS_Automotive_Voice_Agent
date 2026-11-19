#!/usr/bin/env python3
"""PreToolUse guard on Read (specs/token-budget.md item 2, T-900b).

Denies a Read of a text file over the limit (40 KB, NOVA_READ_GUARD_KB; 0 = off) when no offset is given,
so a large spec is read by section instead of whole. Anything else, including the guard's own errors, is allowed.
"""
import json
import os
import sys

NOT_TEXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf", ".ipynb"}
REASON = ("{name} is {kb} KB. Do not read it whole: Grep for the section you need, then Read with offset/limit. "
          "For specs use scripts/spec_section.py <feature> to list sections and <feature> <§> to print one.")


def decide(event: dict, limit_kb: int):
    """None to allow, or the deny reason."""
    if limit_kb <= 0 or event.get("tool_name") != "Read":
        return None
    args = event.get("tool_input") or {}
    path = args.get("file_path")
    if not isinstance(path, str) or args.get("offset") is not None or args.get("limit") is not None:
        return None
    if not os.path.isabs(path) and isinstance(event.get("cwd"), str):
        path = os.path.join(event["cwd"], path)
    if os.path.splitext(path)[1].lower() in NOT_TEXT:
        return None
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    if size <= limit_kb * 1024:
        return None
    return REASON.format(name=os.path.basename(path), kb=size // 1024)


def main() -> int:
    try:
        event = json.load(sys.stdin)
        limit = int(os.environ.get("NOVA_READ_GUARD_KB", "40"))
        reason = decide(event, limit)
    except Exception:
        return 0
    if reason:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                 "permissionDecision": "deny",
                                                 "permissionDecisionReason": reason}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
