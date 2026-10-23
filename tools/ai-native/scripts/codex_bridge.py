#!/usr/bin/env python3
"""External Codex CLI role bridge. Runs real Codex only when explicitly invoked.

Requires installed/authenticated Codex CLI supporting `codex exec`. No test
in this repository invokes a paid model. Never imports project credentials.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REVIEW_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "verdict": {"type": "string", "enum": ["PASS", "REWORK", "BLOCKED", "NOT_VERIFIED"]},
        "reviewed_fingerprint": {"type": "string"},
        "reviewed_contract_hash": {"type": "string"},
        "findings": {"type": "array", "items": {"type": "string"}},
        "next_action": {"type": "string"}
    },
    "required": ["verdict", "reviewed_fingerprint", "reviewed_contract_hash", "findings", "next_action"]
}


def codex_command(role: str, output: Path, schema: Path | None = None) -> list[str]:
    if role == "executor":
        model, effort, sandbox = (os.environ.get("AI_NATIVE_EXECUTOR_MODEL", "gpt-6-luna"),
                                  os.environ.get("AI_NATIVE_EXECUTOR_EFFORT", "medium"), "workspace-write")
    else:
        model, effort, sandbox = (os.environ.get("AI_NATIVE_REVIEWER_MODEL", "gpt-6-astra"),
                                  os.environ.get("AI_NATIVE_REVIEWER_EFFORT", "high"), "read-only")
    command = ["codex", "exec", "--model", model, "--config", "model_reasoning_effort=" + effort,
               "--sandbox", sandbox, "--output-last-message", str(output)]
    if schema:
        command += ["--output-schema", str(schema)]
    return command + ["-"]


def role_prompt(role: str, payload: dict, feedback: dict | None = None) -> str:
    if role == "executor":
        return ("You are an Executor in an AI-native engineering workflow. Work in the current git repo. "
                "Read AGENTS.md and applicable specs; find the existing authoritative implementation owner. "
                "Implement the smallest scoped correct change. Run relevant tests, do not weaken assertions, "
                "do not fabricate success, do not add unnecessary parallel state/architecture, never reveal secrets. "
                "Do not push or merge. If blocked, report exactly why and exit nonzero. "
                "Task contract:\n" + json.dumps(payload, indent=2) + "\n"
                "Feedback from prior attempt (may be absent):\n" + json.dumps(feedback or {}, indent=2))
    return ("You are an INDEPENDENT READ-ONLY software reviewer, not the code author. You must inspect git status, "
            "git diff HEAD and relevant changed files yourself. Check the real behavior against the contract and "
            "required evidence levels. Investigate correctness, security, architecture/invariant drift, failure "
            "cases, tests that prove less than they claim, device/GPU gaps. NEVER edit files, commit or merge. "
            "Return ONLY strict JSON matching the provided schema. reviewed_fingerprint MUST exactly equal "
            "packet.snapshot.fingerprint and reviewed_contract_hash MUST exactly equal packet.contract_hash. "
            "PASS only if all REQUIRED gates actually passed and the task is "
            "satisfied at its asserted evidence level. For failures use REWORK (fixable defect), BLOCKED (named "
            "dependency), or NOT_VERIFIED (insufficient proof). Provide a targeted next_action. "
            "Review packet:\n" + json.dumps(payload, indent=2))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("role", choices=["executor", "reviewer"])
    args = parser.parse_args(argv)
    if not shutil.which("codex"):
        print("Codex CLI not found on PATH; install/authenticate it before running paid model tasks.", file=sys.stderr)
        return 10
    if args.role == "executor":
        path = os.environ.get("AI_NATIVE_CONTRACT")
        if not path:
            print("Missing AI_NATIVE_CONTRACT", file=sys.stderr)
            return 11
        contract = json.loads(Path(path).read_text(encoding="utf-8"))
        feedback_path = os.environ.get("AI_NATIVE_FEEDBACK", "")
        feedback = json.loads(Path(feedback_path).read_text(encoding="utf-8")) if feedback_path and Path(feedback_path).is_file() else None
        prompt = role_prompt("executor", contract, feedback)
        with tempfile.TemporaryDirectory(prefix="ai-native-exec-") as directory:
            output = Path(directory) / "executor-response.txt"
            result = subprocess.run(codex_command("executor", output), input=prompt, text=True, timeout=180)
            return result.returncode
    packet_path, result_path = os.environ.get("AI_NATIVE_REVIEW_PACKET"), os.environ.get("AI_NATIVE_REVIEW_RESULT")
    if not packet_path or not result_path:
        print("Missing review packet/result env paths", file=sys.stderr)
        return 12
    packet = json.loads(Path(packet_path).read_text(encoding="utf-8"))
    prompt = role_prompt("reviewer", packet)
    with tempfile.TemporaryDirectory(prefix="ai-native-review-") as directory:
        schema_path = Path(directory) / "schema.json"
        schema_path.write_text(json.dumps(REVIEW_SCHEMA), encoding="utf-8")
        result = subprocess.run(codex_command("reviewer", Path(result_path).resolve(), schema_path),
                                input=prompt, text=True, timeout=180)
    return result.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        print("Codex role failed: " + str(error), file=sys.stderr)
        raise SystemExit(13)
