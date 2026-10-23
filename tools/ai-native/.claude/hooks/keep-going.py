#!/usr/bin/env python3
"""Portable Claude Stop continuation hook adapted from Nova Drive keep-going.py.

Only an explicitly configured, validated frontier may authorize continuation.
The deterministic control plane decides eligibility; this hook cannot mark work
PASS or bypass the optional review gate. Each session has a hard block cap and a
shorter unchanged-frontier cap to prevent runaway Stop chains.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from control_plane import canonical_hash, decide_frontier, verify_decision
from frontier import check, fingerprint, load

MAX_BLOCKS = 20
MAX_UNCHANGED_BLOCKS = 3
ASKING = re.compile(
    r"\b(want me to|would you like( me)? to|should i|shall i|do you want( me)? to|"
    r"let me know if|if you want(,| me to)|say the word|ready when you are)\b",
    re.IGNORECASE,
)
SAFE_TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$")


def warning(message: str) -> None:
    print("AI-native continuation: " + message, file=sys.stderr)


def review_is_current(repo: Path) -> bool:
    """Do not advance the frontier past enabled-but-unverified end-state review."""
    if os.environ.get("AI_NATIVE_STOP_ENABLED") != "1":
        return True
    contract_name = os.environ.get("AI_NATIVE_CONTRACT_PATH")
    if not contract_name:
        warning("review is enabled but AI_NATIVE_CONTRACT_PATH is absent; no continuation")
        return False
    contract_path = Path(contract_name)
    if not contract_path.is_absolute():
        contract_path = repo / contract_path
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        task_id = contract["task_id"]
        if not isinstance(task_id, str) or not SAFE_TASK_ID.fullmatch(task_id):
            raise ValueError("invalid task_id")
        report = json.loads((repo / ".ai-native" / "runs" / task_id / "latest.json").read_text(encoding="utf-8"))
        from ai_native import work_snapshot
        current = work_snapshot(repo)["fingerprint"]
        decision = report.get("control_plane_decision")
        valid = (
            report.get("verdict") == "PASS"
            and report.get("snapshot", {}).get("fingerprint") == current
            and report.get("reviewed_fingerprint") == current
            and report.get("contract_hash") == canonical_hash(contract)
            and report.get("reviewed_contract_hash") == canonical_hash(contract)
            and isinstance(decision, dict)
            and verify_decision(decision)
            and decision.get("action") == "TASK_VERIFIED"
        )
        if not valid:
            warning("review proof is missing or stale; run a current task cycle before continuation")
        return valid
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        warning("cannot validate current review proof (" + type(exc).__name__ + "); no continuation")
        return False


def state_file(repo: Path, event: dict) -> Path:
    # Hash the Claude session id: no unsafe filenames and separate concurrent sessions.
    session = str(event.get("session_id") or "")
    if not session:
        raise ValueError("missing Claude session_id")
    ident = hashlib.sha256(session.encode("utf-8")).hexdigest()[:24]
    return repo / ".ai-native" / "hook-cycle" / (ident + ".json")


def read_state(path: Path) -> dict:
    try:
        saved = json.loads(path.read_text(encoding="utf-8"))
        return saved if isinstance(saved, dict) else {}
    except (OSError, ValueError, json.JSONDecodeError):
        return {}


def write_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temp, path)


def route(event: dict, repo: Path, registry: Path) -> tuple[bool, str]:
    """Return (block_stop, reason); never invent tasks or override control_plane."""
    data = load(registry)
    errors = check(data)
    if errors:
        warning("invalid work registry: " + "; ".join(errors[:4]))
        return False, ""
    decision = decide_frontier(data["work"])
    if not verify_decision(decision):
        warning("invalid deterministic frontier decision")
        return False, ""
    action = decision["action"]
    if action != "CONTINUE_FRONTIER":
        # WAIT_EXTERNAL, DISCOVERY_REQUIRED, HUMAN_HANDOFF and STOP_COMPLETE all
        # permit Claude to stop; owner-only work must not be auto-executed.
        if action == "INVALID_STATE":
            warning("invalid frontier state: " + "; ".join(decision["reasons"][:4]))
        return False, ""

    candidates = decision["frontier"]["autonomous"]
    if not candidates:
        warning("inconsistent control-plane frontier")
        return False, ""
    if not review_is_current(repo):
        return False, ""

    next_work = candidates[0]
    key = canonical_hash({"registry": fingerprint(data), "next": next_work["id"]})
    path = state_file(repo, event)
    old = read_state(path) if event.get("stop_hook_active") is True else {}
    total = old.get("blocks", 0) if isinstance(old.get("blocks", 0), int) else 0
    unchanged = old.get("unchanged", 0) if old.get("key") == key else 0
    if total >= MAX_BLOCKS or unchanged >= MAX_UNCHANGED_BLOCKS:
        warning("bounded Stop chain exhausted (blocks=%s, unchanged=%s); "
                "inspect the task and update registry evidence before a new run" % (total, unchanged))
        return False, ""

    write_state(path, {"key": key, "blocks": total + 1, "unchanged": unchanged + 1})
    reason = (
        "AI-native deterministic frontier: authorized autonomous work remains "
        "(%d eligible). Do not end this turn. NEXT_ACTION [%s]: %s. "
        "Use the existing task contract and Executor; run objective gates and "
        "independent review, then update work-registry status with real evidence. "
        "Do not mark PASS merely because the implementation looks complete."
        % (len(candidates), next_work["id"], next_work["action"])
    )
    last = event.get("last_assistant_message", "")
    if isinstance(last, str) and ASKING.search(last[-1500:]):
        reason += (
            " Do not ask the owner for permission to do already-authorized routine work. "
            "Keep genuinely human-only, credential, and irreversible choices deferred."
        )
    return True, reason


def main() -> int:
    if os.environ.get("AI_NATIVE_CONTINUE_ENABLED") != "1":
        return 0
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise ValueError("Stop event must be an object")
        repo = Path(os.environ.get("CLAUDE_PROJECT_DIR") or Path.cwd()).resolve()
        name = os.environ.get("AI_NATIVE_WORK_REGISTRY")
        if not name:
            warning("AI_NATIVE_WORK_REGISTRY is unset; continuation is disabled")
            return 0
        registry = Path(name)
        if not registry.is_absolute():
            registry = repo / registry
        block, reason = route(event, repo, registry)
        if block:
            print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        # Fail open as a Stop hook, but never emit PASS on invalid state.
        warning("unable to discover an authorized next action (" + type(exc).__name__ + ")")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
