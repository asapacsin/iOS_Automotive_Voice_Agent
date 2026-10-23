#!/usr/bin/env python3
"""Canonical dependency-aware autonomous frontier + batched human work gate.

JSON registry deliberately separate from prompt. It detects cycles, propagates
blockers only to dependants, requires evidence for PASS, and never invents tests.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import sys
from pathlib import Path

from control_plane import decide_frontier

STATUSES = {"NOT_RUN", "RUNNING", "PASS", "FAIL", "BLOCKED_EXTERNAL", "HUMAN_REQUIRED", "NOT_APPLICABLE"}
OWNERS = {"AUTONOMOUS", "HUMAN_PHYSICAL", "HUMAN_DECISION", "HUMAN_CREDENTIAL", "EXTERNAL_RESOURCE"}
TERMINAL = {"PASS", "NOT_APPLICABLE"}


def load(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("registry must be a JSON object")
    return data


def check(data: dict) -> list[str]:
    errors = []
    if data.get("schema_version") != 1 or not isinstance(data.get("work"), list):
        return ["schema_version=1 and work list are required"]
    by_id = {}
    for task in data["work"]:
        if not isinstance(task, dict) or not isinstance(task.get("id"), str) or not task["id"]:
            errors.append("each work item needs an id")
            continue
        name = task["id"]
        if name in by_id:
            errors.append("duplicate item " + name)
        by_id[name] = task
        if task.get("owner") not in OWNERS or task.get("status") not in STATUSES:
            errors.append(name + ": invalid owner or status")
        if not isinstance(task.get("depends_on"), list):
            errors.append(name + ": depends_on list required")
        if not str(task.get("action", "")).strip():
            errors.append(name + ": actionable command/instruction required")
        status = task.get("status")
        if status == "PASS" and not task.get("evidence"):
            errors.append(name + ": PASS without evidence")
        if status == "BLOCKED_EXTERNAL" and not task.get("blocked_by"):
            errors.append(name + ": missing concrete blocker")
        if status == "HUMAN_REQUIRED":
            if not str(task.get("owner", "")).startswith("HUMAN_"):
                errors.append(name + ": human work needs HUMAN_* owner")
            for field in ("automation_blocker", "procedure", "expected_return", "pass_criteria"):
                if not str(task.get(field, "")).strip():
                    errors.append(name + ": missing human " + field)
            if task.get("owner") == "HUMAN_DECISION" and not task.get("quantified"):
                errors.append(name + ": decision requires quantified options")
    graph = {name: item.get("depends_on", []) for name, item in by_id.items()}
    for name, deps in graph.items():
        if not isinstance(deps, list):
            continue
        for dependency in deps:
            if dependency not in by_id:
                errors.append(name + ": unknown dependency " + str(dependency))
    visited, active = set(), set()

    def dfs(name):
        if name in active:
            errors.append("dependency cycle at " + name)
            return
        if name in visited:
            return
        active.add(name)
        for dep in graph.get(name, []):
            if dep in graph:
                dfs(dep)
        active.remove(name)
        visited.add(name)

    for name in by_id:
        dfs(name)
    return errors


def frontier(data: dict) -> dict:
    issues = check(data)
    if issues:
        raise ValueError("; ".join(issues))
    decision = decide_frontier(data["work"])
    report = dict(decision.get("frontier", {}))
    report["control_decision"] = decision["action"]
    report["decision_sha256"] = decision["decision_sha256"]
    return report


def fingerprint(data: dict) -> str:
    return hashlib.sha256(json.dumps(data, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def readiness(data: dict, state: dict) -> list[str]:
    f = frontier(data)
    issues = []
    if f["autonomous"]:
        issues.append("autonomous work remains; continue before human handoff")
    if any(w["status"] == "FAIL" for w in data["work"]):
        issues.append("unresolved failing work")
    if not f["human"]:
        issues.append("no human validation queue")
    if state.get("clean_passes", 0) < 2 or state.get("fingerprint") != fingerprint(data):
        issues.append("two independent clean discovery/review passes required on current registry")
    return issues


def clean_pass(data: dict, state: dict, independent: bool) -> dict:
    f = frontier(data)
    current = fingerprint(data)
    if f["autonomous"] or not independent:
        return {"fingerprint": current, "clean_passes": 0}
    n = state.get("clean_passes", 0) if state.get("fingerprint") == current else 0
    return {"fingerprint": current, "clean_passes": min(2, n + 1)}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["check", "next", "human-packet", "clean-pass", "human-gate"])
    p.add_argument("--registry", required=True)
    p.add_argument("--state", help="private progress state (default <registry>.frontier-state.json)")
    p.add_argument("--independent", action="store_true", help="confirm separate independent discovery/review pass")
    args = p.parse_args(argv)
    try:
        path = Path(args.registry)
        data = load(path)
        problems = check(data)
        if problems:
            raise ValueError("; ".join(problems))
        statefile = Path(args.state) if args.state else path.with_name(".frontier-state.json")
        state = load(statefile) if statefile.is_file() else {}
        if args.action == "clean-pass":
            state = clean_pass(data, state, args.independent)
            statefile.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(state, indent=2))
            return 0
        report = frontier(data)
        if args.action == "human-gate":
            issues = readiness(data, state)
            decision = decide_frontier(data["work"], state.get("clean_passes", 0),
                                       state.get("fingerprint"), fingerprint(data))
            ready = not issues and decision["action"] == "HUMAN_HANDOFF"
            print(json.dumps({"phase": "HUMAN_VALIDATION_READY" if ready else "NOT_READY",
                              "control_decision": decision["action"], "problems": issues}, indent=2))
            return 0 if ready else 2
        if args.action == "human-packet":
            report = {"items": report["human"], "count": len(report["human"]),
                      "warning": "Human tasks have not been performed or approved"}
        if args.action == "check":
            report = {"valid": True, "count": len(data["work"])}
        print(json.dumps(report, indent=2))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print("INVALID:", str(e), file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
