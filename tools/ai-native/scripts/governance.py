#!/usr/bin/env python3
"""Fail-closed task approval, path scope, and exact-tip merge eligibility.

Requires a normal Git worktree, a task contract, and a saved ai_native cycle
verdict. This is a local process guard, NOT GitHub branch protection or cryptographic
actor authentication. The approver identity is self-asserted; protect the CI job
and governance records with repository permissions/branch rules in production.
"""
from __future__ import annotations
import argparse
import fnmatch
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

from ai_native import load_json, work_snapshot, validate_contract, save_json
from control_plane import decide_integration, verify_decision

LEVELS = ["static", "unit", "integration", "e2e", "device", "visual", "performance"]
PROTECTED = (".git/", ".ai-native/", ".github/workflows/", "AGENTS.md",
             "verification/requirements.json", "state/contracts/", "state/reviews.log")


def digest(obj: dict) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def patterns_match(path: str, rule: str) -> bool:
    """Git-style directory prefix or slash-aware * and ** patterns."""
    import re
    rule = rule.replace("\\", "/")
    if rule.endswith("/"):
        return path.startswith(rule)
    expression = ""
    i = 0
    while i < len(rule):
        if rule[i:i + 3] == "**/":
            expression += "(?:.*/)?"
            i += 3
        elif rule[i:i + 2] == "**":
            expression += ".*"
            i += 2
        elif rule[i] == "*":
            expression += "[^/]*"
            i += 1
        elif rule[i] == "?":
            expression += "[^/]"
            i += 1
        else:
            expression += re.escape(rule[i])
            i += 1
    return re.fullmatch(expression, path) is not None


def changed_paths(repo: Path, base: str) -> list[str]:
    subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{base}^{{commit}}"],
                   check=True, capture_output=True)
    paths: set[str] = set()
    for args in (["diff", "--no-renames", "--name-only", "-z", base, "HEAD"],
                 ["diff", "--no-renames", "--name-only", "-z", "HEAD"],
                 ["ls-files", "-o", "--exclude-standard", "-z"]):
        output = subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True).stdout
        for p in output.split(b"\0"):
            if p:
                paths.add(p.decode("utf-8", errors="surrogateescape").replace("\\", "/"))
    return sorted(paths)


def contract_policy(contract: dict) -> list[str]:
    issues: list[str] = []
    try:
        validate_contract(contract)
    except (ValueError, TypeError) as exc:
        return [str(exc)]
    if not isinstance(contract.get("base_commit"), str) or len(contract["base_commit"]) != 40:
        issues.append("base_commit must be a full 40-character Git commit SHA")
    allowed = contract.get("approved_paths")
    forbidden = contract.get("forbidden_paths", [])
    if not isinstance(allowed, list) or not allowed or not all(isinstance(x, str) and x for x in allowed):
        issues.append("approved_paths must be a nonempty string list")
    if not isinstance(forbidden, list) or not all(isinstance(x, str) and x for x in forbidden):
        issues.append("forbidden_paths must be a string list")
    return issues


def scope_issues(repo: Path, contract: dict) -> list[str]:
    issues = contract_policy(contract)
    if issues:
        return issues
    try:
        paths = changed_paths(repo, contract["base_commit"])
    except subprocess.CalledProcessError:
        return ["base_commit is missing from this Git checkout"]
    for p in paths:
        if any(p == x.rstrip("/") or p.startswith(x) for x in PROTECTED):
            issues.append("protected governance file changed: " + p)
        elif any(patterns_match(p, g) for g in contract.get("forbidden_paths", [])):
            issues.append("forbidden path changed: " + p)
        elif not any(patterns_match(p, g) for g in contract["approved_paths"]):
            issues.append("outside approved scope: " + p)
    return issues


def approval_path(repo: Path, task_id: str) -> Path:
    return repo / ".ai-native" / "approvals" / (task_id + ".json")


def approve(repo: Path, contract: dict, actor: str, role: str) -> dict:
    errs = contract_policy(contract)
    if errs:
        raise ValueError("; ".join(errs))
    if role not in {"planner", "architect", "owner"} or os.getenv("AI_NATIVE_ROLE", "").lower() == "executor":
        raise ValueError("executor cannot approve task contracts")
    if not actor.strip():
        raise ValueError("named approver required")
    # Local approval is a procedural control, not strong authentication.
    item = {"task_id": contract["task_id"], "contract_hash": digest(contract),
            "actor": actor, "role": role, "base_commit": contract["base_commit"]}
    save_json(approval_path(repo, contract["task_id"]), item)
    return item


def evidence_level_satisfies(actual: str, minimum: str) -> bool:
    # Device, visual and performance are separate proof domains, not a linear ladder.
    standard = ["static", "unit", "integration", "e2e"]
    if minimum in standard:
        return actual in standard and standard.index(actual) >= standard.index(minimum)
    return actual == minimum


def verified_terminal_artifact(repo: Path, reference: dict, expected: str, fingerprint: str) -> str | None:
    """Verify an on-disk terminal trace by checksum and observed, natural final state."""
    import re
    if not isinstance(reference, dict):
        return "artifact reference must include relative path and sha256"
    rel, expected_digest = reference.get("path"), reference.get("sha256")
    if not isinstance(rel, str) or not isinstance(expected_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
        return "artifact requires a valid relative path and sha256"
    path = (repo / rel).resolve()
    if not path.is_relative_to(repo.resolve()) or not path.is_file():
        return "terminal artifact path missing or escapes repository"
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected_digest:
        return "terminal artifact checksum mismatch"
    try:
        record = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return "terminal artifact is not JSON"
    if (not isinstance(record, dict) or record.get("observed_terminal") != expected
            or record.get("ended_naturally") is not True
            or record.get("source_fingerprint") != fingerprint):
        return "terminal outcome, natural end or source fingerprint was not observed"
    return None


def required_evidence_issues(repo: Path, requirements: dict, latest: dict) -> list[str]:
    """Independent requirement-owned minimum scope and real terminal artifact binding."""
    problems: list[str] = []
    if (requirements.get("schema_version") != 1 or
            not isinstance(requirements.get("requirements"), list) or not requirements["requirements"]):
        return ["independent requirements manifest must have schema_version=1 and nonempty requirements"]
    gates_path = repo / ".ai-native" / "runs" / latest.get("task_id", "")
    attempt = int(latest.get("attempt", 0))
    datafile = gates_path / f"attempt-{attempt:02}" / "gates.json"
    try:
        records = {g["id"]: g for g in load_json(datafile)["gates"]}
    except (OSError, ValueError, TypeError, KeyError):
        return ["final attempt gate evidence unavailable"]
    for req in requirements["requirements"]:
        if not isinstance(req, dict) or not req.get("id"):
            problems.append("requirement entry missing id")
            continue
        level = req.get("min_level")
        if level not in LEVELS:
            problems.append(f"{req['id']}: invalid min_level")
            continue
        gate_ids = req.get("gate_ids", [])
        if not isinstance(gate_ids, list) or not gate_ids:
            problems.append(f"{req['id']}: no required gates declared")
            continue
        for gid in gate_ids:
            evidence = records.get(gid)
            if not evidence or evidence.get("status") != "PASS":
                problems.append(f"{req['id']}: required gate {gid} has no passing evidence")
            elif not evidence_level_satisfies(evidence.get("level", "static"), level):
                problems.append(f"{req['id']}: gate {gid} scope below required {level}")
        if req.get("terminal_required"):
            terminal = req.get("terminal_state")
            refs = req.get("artifact_refs", [])
            if not isinstance(terminal, str) or not terminal or not isinstance(refs, list) or not refs:
                problems.append(f"{req['id']}: missing terminal state or artifact reference")
            else:
                fingerprint = latest.get("snapshot", {}).get("fingerprint")
                for reference in refs:
                    try:
                        reason = verified_terminal_artifact(repo, reference, terminal, fingerprint)
                    except (OSError, ValueError):
                        reason = "terminal artifact unreadable"
                    if reason:
                        problems.append(f"{req['id']}: {reason}")
    return problems


def eligibility(repo: Path, contract: dict, requirements: dict | None = None) -> list[str]:
    scope_problems = scope_issues(repo, contract)
    issues = list(scope_problems)
    approval_ok = False
    try:
        approval = load_json(approval_path(repo, contract["task_id"]))
        approval_ok = (approval.get("contract_hash") == digest(contract)
                       and approval.get("role") in {"planner", "architect", "owner"})
        if approval.get("contract_hash") != digest(contract):
            issues.append("contract changed since independent approval")
        if approval.get("role") not in {"planner", "architect", "owner"}:
            issues.append("invalid approval role")
    except (OSError, ValueError):
        issues.append("missing independent task approval")
    snapshot = work_snapshot(repo)
    if snapshot["dirty"]:
        issues.append("worktree must be clean before merge eligibility")
    review_pass = review_current = contract_current = required_gates_pass = requirements_pass = False
    try:
        latest = load_json(repo / ".ai-native" / "runs" / contract["task_id"] / "latest.json")
        control_decision = latest.get("control_plane_decision", {})
        deterministic_pass = (control_decision.get("action") == "TASK_VERIFIED"
                              and verify_decision(control_decision))
        review_pass = latest.get("verdict") == "PASS" and deterministic_pass
        if not deterministic_pass:
            issues.append("deterministic control-plane PASS missing or invalid")
        review_current = latest.get("snapshot", {}).get("fingerprint") == snapshot["fingerprint"]
        contract_current = latest.get("contract_hash") == digest(contract)
        required_gates_pass = not latest.get("failed_required_gates")
        if not review_pass:
            issues.append("independent reviewer did not PASS")
        if not review_current:
            issues.append("verification or review is stale relative to current tree")
        if not contract_current:
            issues.append("verification not bound to approved contract")
        if not required_gates_pass:
            issues.append("some required gates failed")
        latest["task_id"] = contract["task_id"]
        if requirements is not None:
            req_problems = required_evidence_issues(repo, requirements, latest)
            issues.extend(req_problems)
            requirements_pass = not req_problems
        else:
            requirements_pass = True
    except (OSError, ValueError):
        issues.append("no current end-state verification available")
    control = decide_integration({
        "contract_approved": approval_ok,
        "scope_clean": not scope_problems,
        "review_pass": review_pass,
        "review_current": review_current,
        "contract_current": contract_current,
        "required_gates_pass": required_gates_pass,
        "requirements_pass": requirements_pass,
        "source_clean": not snapshot["dirty"],
        "frontier_complete": True,
        "human_clear": True,
        "external_clear": True
    })
    if control["action"] != "READY_TO_MERGE" and not issues:
        issues.extend(control["reasons"])
    return issues


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["approve", "scope", "eligible"])
    parser.add_argument("--repo", default=".")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--requirements")
    parser.add_argument("--actor", default="")
    parser.add_argument("--role", default="executor")
    args = parser.parse_args(argv)
    try:
        repo = Path(args.repo).resolve()
        contract = load_json(Path(args.contract))
        if args.action == "approve":
            print(json.dumps(approve(repo, contract, args.actor, args.role), indent=2))
            return 0
        if args.action == "eligible" and not args.requirements:
            raise ValueError("eligible requires an independent --requirements manifest")
        problems = (scope_issues(repo, contract) if args.action == "scope" else
                    eligibility(repo, contract, load_json(Path(args.requirements)) if args.requirements else None))
        print(json.dumps({"result": "ELIGIBLE" if not problems else "NOT_ELIGIBLE", "problems": problems}, indent=2))
        return 0 if not problems else 2
    except (ValueError, OSError, subprocess.CalledProcessError) as e:
        print("BLOCKED:", str(e), file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
