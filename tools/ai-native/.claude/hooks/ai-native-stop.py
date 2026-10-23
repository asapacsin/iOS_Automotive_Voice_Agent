#!/usr/bin/env python3
"""Claude Code Stop entry point: serialized end-state review, then bounded frontier.

The review hook must run first. Registering a second independent Stop command
could race the review and accidentally resume from an older PASS. This one entry
point preserves the original opt-in end-state behavior and invokes the portable
keep-going hook only after verification has succeeded (or review is disabled).
"""
import json
import os
import subprocess
import sys
from pathlib import Path


def main():
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise ValueError("invalid Claude Stop event")
        repo = Path(os.environ.get("CLAUDE_PROJECT_DIR", ".")).resolve()
        if os.environ.get("AI_NATIVE_STOP_ENABLED") == "1" and not event.get("stop_hook_active"):
            contract = os.environ.get("AI_NATIVE_CONTRACT_PATH")
            if not contract:
                print("AI-native review enabled without AI_NATIVE_CONTRACT_PATH", file=sys.stderr)
                return 0
            script = Path(__file__).resolve().parents[2] / "scripts" / "ai_native.py"
            process = subprocess.run(
                [sys.executable, str(script), "cycle", "--repo", str(repo), "--contract", contract],
                capture_output=True, text=True, timeout=360,
            )
            if process.returncode == 2:
                print(json.dumps({
                    "decision": "block",
                    "reason": "AI-native review: REWORK. Read .ai-native/runs/*/latest.json, "
                              "fix targeted issues, rerun tests. Bounded Stop review: "
                              "only one automatic review block per Stop chain."
                }))
                return 0
            if process.returncode != 0:
                # Cannot advance unfinished work using a failed/missing review.
                print(process.stdout[-1000:] +
                      "\nAI-native verdict not PASS; review evidence and dependencies.",
                      file=sys.stderr)
                return 0

        if os.environ.get("AI_NATIVE_CONTINUE_ENABLED") == "1":
            child = Path(__file__).resolve().with_name("keep-going.py")
            result = subprocess.run(
                [sys.executable, str(child)], input=json.dumps(event),
                capture_output=True, text=True, timeout=15,
            )
            if result.stderr:
                print(result.stderr.rstrip(), file=sys.stderr)
            if result.returncode != 0:
                print("AI-native continuation hook failed; no continuation", file=sys.stderr)
                return 0
            if result.stdout.strip():
                # Child emits only a Claude Stop decision JSON, never a PASS claim.
                print(result.stdout.strip())
    except Exception as exc:
        # Hook runtime failure is visible, but must not trap Claude indefinitely.
        print("AI-native Stop hook could not verify/continue: " + str(exc), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
