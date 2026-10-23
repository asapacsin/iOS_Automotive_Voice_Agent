"""Behavioral checks for the end-state controller. Reviewer helpers are test doubles."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import ai_native as engine


class AiNativeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / "project"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        (self.repo / ".gitignore").write_text(".ai-native/\n__pycache__/\n", encoding="utf-8")
        (self.repo / "app.py").write_text("value = 1\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "-qm", "initial"], cwd=self.repo, check=True)
        self.contract = {"schema_version": 1, "task_id": "trial", "goal": "Do good work",
                         "acceptance": "Test the actual app behavior",
                         "budgets": {"max_attempts": 3, "max_total_seconds": 30},
                         "gates": [{"id": "gate", "level": "unit", "command":
                                    [sys.executable, "-c", "print('ok')"], "timeout_seconds": 10}]}
        self.reviewer_path = self.root / "reviewer.py"
        self.write_reviewer()

    def tearDown(self):
        self.tmp.cleanup()

    def write_reviewer(self, verdict="PASS", wrong_fingerprint=False, mutate=False, wrong_contract_hash=False):
        self.reviewer_path.write_text(
            "import os,json,pathlib\n"
            "packet=json.loads(pathlib.Path(os.environ['AI_NATIVE_REVIEW_PACKET']).read_text())\n"
            + ("pathlib.Path('app.py').write_text('value = 9\\n')\n" if mutate else "")
            + "pathlib.Path(os.environ['AI_NATIVE_REVIEW_RESULT']).write_text(json.dumps({"
            + f"'verdict':'{verdict}',"
            + ("'reviewed_fingerprint':'wrong'," if wrong_fingerprint else
               "'reviewed_fingerprint':packet['snapshot']['fingerprint'],")
            + ("'reviewed_contract_hash':'wrong'," if wrong_contract_hash else "'reviewed_contract_hash':packet['contract_hash'],")
            + "'findings':[],'next_action':'done'}))\n", encoding="utf-8")

    def call(self, with_reviewer=True):
        contract_path = self.root / "contract.json"
        contract_path.write_text(json.dumps(self.contract), encoding="utf-8")
        args = ["cycle", "--repo", str(self.repo), "--contract", str(contract_path)]
        if with_reviewer:
            args.extend(["--reviewer", f'"{sys.executable}" "{self.reviewer_path}"'])
        code = engine.main(args)
        outcome = engine.load_json(self.repo / ".ai-native" / "runs" / "trial" / "latest.json")
        return code, outcome

    def test_contract_validation(self):
        engine.validate_contract(self.contract)

    def test_reject_missing_goal(self):
        self.contract["goal"] = ""
        with self.assertRaises(ValueError):
            engine.validate_contract(self.contract)

    def test_reject_duplicate_gates(self):
        self.contract["gates"].append(dict(self.contract["gates"][0]))
        with self.assertRaises(ValueError):
            engine.validate_contract(self.contract)

    def test_pass_with_external_reviewer_and_unit_gate(self):
        code, outcome = self.call()
        self.assertEqual(code, 0)
        self.assertEqual(outcome["verdict"], "PASS")
        self.assertEqual(outcome["control_plane_decision"]["action"], "TASK_VERIFIED")
        self.assertEqual(len(outcome["snapshot"]["commit"]), 40)

    def test_no_reviewer_is_not_verified(self):
        code, outcome = self.call(False)
        self.assertEqual(code, 4)
        self.assertEqual(outcome["verdict"], "NOT_VERIFIED")

    def test_gate_failure_cannot_be_overridden_by_reviewer(self):
        self.contract["gates"][0]["command"] = [sys.executable, "-c", "raise SystemExit(1)"]
        code, outcome = self.call()
        self.assertEqual(code, 2)
        self.assertEqual(outcome["verdict"], "REWORK")
        self.assertIn("gate", outcome["failed_required_gates"])

    def test_missing_gate_binary_is_blocked(self):
        self.contract["gates"][0]["command"] = ["missing_command_419167"]
        code, outcome = self.call()
        self.assertEqual(code, 3)
        self.assertEqual(outcome["verdict"], "BLOCKED")

    def test_wrong_fingerprint_not_verified(self):
        self.write_reviewer(wrong_fingerprint=True)
        code, outcome = self.call()
        self.assertEqual(code, 4)
        self.assertEqual(outcome["verdict"], "NOT_VERIFIED")

    def test_wrong_contract_hash_not_verified(self):
        self.write_reviewer(wrong_contract_hash=True)
        code, outcome = self.call()
        self.assertEqual(code, 4)
        self.assertEqual(outcome["verdict"], "NOT_VERIFIED")

    def test_reviewer_mutation_not_verified(self):
        self.write_reviewer(mutate=True)
        code, outcome = self.call()
        self.assertEqual(code, 4)
        self.assertEqual(outcome["verdict"], "NOT_VERIFIED")

    def test_untracked_contents_affect_fingerprint(self):
        old = engine.work_snapshot(self.repo)["fingerprint"]
        (self.repo / "new.txt").write_text("first", encoding="utf-8")
        mid = engine.work_snapshot(self.repo)["fingerprint"]
        (self.repo / "new.txt").write_text("second", encoding="utf-8")
        new = engine.work_snapshot(self.repo)["fingerprint"]
        self.assertEqual(len({old, mid, new}), 3)

    def test_dirty_tracked_contents_affect_fingerprint(self):
        old = engine.work_snapshot(self.repo)
        (self.repo / "app.py").write_text("value = 2\n", encoding="utf-8")
        new = engine.work_snapshot(self.repo)
        self.assertNotEqual(old["fingerprint"], new["fingerprint"])
        self.assertTrue(new["dirty"])

    def test_optional_gate_can_fail_without_blocking_pass(self):
        self.contract["gates"].append({"id":"optional", "level":"static", "required":False,
                                       "command":[sys.executable,"-c","raise SystemExit(1)"]})
        code, outcome = self.call()
        self.assertEqual(code, 0)
        self.assertEqual(outcome["failed_required_gates"], [])

    def test_rework_decision_and_no_executor_has_no_auto_retry(self):
        self.write_reviewer(verdict="REWORK")
        code, outcome = self.call()
        self.assertEqual(code, 2)
        self.assertFalse((self.repo / ".ai-native" / "runs" / "trial" / "attempt-02").exists())

    def test_hook_noop_without_enable(self):
        hook = Path(__file__).resolve().parents[1] / ".claude" / "hooks" / "ai-native-stop.py"
        result = subprocess.run([sys.executable, str(hook)], input=json.dumps({"stop_hook_active":False}),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
