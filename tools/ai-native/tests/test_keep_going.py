"""Regression tests for portable, bounded Claude Stop continuation."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / ".claude" / "hooks" / "keep-going.py"


def task(name, status="NOT_RUN", depends=None, **extra):
    return {"id": name, "owner": "AUTONOMOUS", "status": status,
            "action": "Execute " + name, "depends_on": depends or [], **extra}


class KeepGoingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.registry = self.repo / "work.json"
        self.set_work([task("one")])

    def set_work(self, work):
        self.registry.write_text(json.dumps({"schema_version": 1, "work": work}), encoding="utf-8")

    def run_hook(self, event=None, extra_env=None):
        if event is None:
            event = {"session_id": "session-A", "stop_hook_active": False}
        env = dict(os.environ)
        for key in ("AI_NATIVE_STOP_ENABLED", "AI_NATIVE_CONTRACT_PATH",
                    "AI_NATIVE_CONTINUE_ENABLED", "AI_NATIVE_WORK_REGISTRY"):
            env.pop(key, None)
        env.update({"AI_NATIVE_CONTINUE_ENABLED": "1",
                    "AI_NATIVE_WORK_REGISTRY": str(self.registry),
                    "CLAUDE_PROJECT_DIR": str(self.repo)})
        env.update(extra_env or {})
        result = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(event),
                                capture_output=True, text=True, env=env, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return (json.loads(result.stdout) if result.stdout.strip() else None, result.stderr)

    def test_blocks_on_authorized_action(self):
        result, _ = self.run_hook()
        self.assertEqual(result["decision"], "block")
        self.assertIn("NEXT_ACTION [one]", result["reason"])

    def test_blocked_item_does_not_block_independent_item(self):
        self.set_work([task("gpu", "BLOCKED_EXTERNAL", blocked_by="GPU unavailable"),
                       task("render", depends=["gpu"]), task("docs")])
        result, _ = self.run_hook()
        self.assertIn("NEXT_ACTION [docs]", result["reason"])

    def test_all_done_allows_stop(self):
        self.set_work([task("done", "PASS", evidence=["test-log"])])
        result, _ = self.run_hook()
        self.assertIsNone(result)

    def test_human_only_allows_stop(self):
        self.set_work([{"id": "device", "owner": "HUMAN_PHYSICAL",
                        "status": "HUMAN_REQUIRED", "action": "Run manual acceptance",
                        "depends_on": [], "automation_blocker": "physical device",
                        "procedure": "Test on hardware", "expected_return": "device notes",
                        "pass_criteria": "works on device"}])
        result, _ = self.run_hook()
        self.assertIsNone(result)

    def test_invalid_registry_does_not_authorize_work(self):
        self.set_work([task("a", depends=["b"]), task("b", depends=["a"])])
        result, err = self.run_hook()
        self.assertIsNone(result)
        self.assertIn("invalid work registry", err)

    def test_no_progress_is_bounded_even_when_hook_active(self):
        self.assertIsNotNone(self.run_hook()[0])
        event = {"session_id": "session-A", "stop_hook_active": True}
        self.assertIsNotNone(self.run_hook(event)[0])
        self.assertIsNotNone(self.run_hook(event)[0])
        result, err = self.run_hook(event)
        self.assertIsNone(result)
        self.assertIn("bounded Stop chain exhausted", err)

    def test_registry_progress_resets_unchanged_counter(self):
        self.assertIsNotNone(self.run_hook()[0])
        event = {"session_id": "session-A", "stop_hook_active": True}
        self.assertIsNotNone(self.run_hook(event)[0])
        self.set_work([task("one", "PASS", evidence=["verified"]), task("two")])
        result, _ = self.run_hook(event)
        self.assertIn("NEXT_ACTION [two]", result["reason"])

    def test_permission_question_produces_continue_instruction(self):
        event = {"session_id": "s", "stop_hook_active": False,
                 "last_assistant_message": "Want me to keep going?"}
        result, _ = self.run_hook(event)
        self.assertIn("Do not ask the owner", result["reason"])

    def test_serialized_stop_entry_point_invokes_continuation(self):
        wrapper = ROOT / ".claude" / "hooks" / "ai-native-stop.py"
        env = dict(os.environ)
        env.pop("AI_NATIVE_STOP_ENABLED", None)
        env.update({"AI_NATIVE_CONTINUE_ENABLED": "1",
                    "AI_NATIVE_WORK_REGISTRY": str(self.registry),
                    "CLAUDE_PROJECT_DIR": str(self.repo)})
        result = subprocess.run(
            [sys.executable, str(wrapper)],
            input=json.dumps({"session_id": "sequential", "stop_hook_active": False}),
            capture_output=True, text=True, env=env, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NEXT_ACTION [one]", json.loads(result.stdout)["reason"])

    def test_disabled_is_a_noop(self):
        result, _ = self.run_hook(extra_env={"AI_NATIVE_CONTINUE_ENABLED": "0"})
        self.assertIsNone(result)

    def test_missing_registry_does_not_guess_from_example(self):
        result, err = self.run_hook(extra_env={"AI_NATIVE_WORK_REGISTRY": ""})
        self.assertIsNone(result)
        self.assertIn("is unset", err)

    def test_enabled_review_without_proof_stops_continuation(self):
        result, err = self.run_hook(extra_env={"AI_NATIVE_STOP_ENABLED": "1"})
        self.assertIsNone(result)
        self.assertIn("review is enabled", err)

    def test_malformed_event_does_not_wedge_stop(self):
        result, err = self.run_hook(event={"stop_hook_active": False})
        self.assertIsNone(result)
        self.assertIn("unable to discover", err)


if __name__ == "__main__":
    unittest.main()
