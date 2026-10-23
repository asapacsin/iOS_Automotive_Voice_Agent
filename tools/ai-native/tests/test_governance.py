"""P0 safeguards must reject the dangerous paths, not just happy cases."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import ai_native
import control_plane
import governance


class GovernanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        (self.repo / ".gitignore").write_text(".ai-native/\n", encoding="utf-8")
        (self.repo / "app.py").write_text("ok\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=t@example.invalid",
                        "commit", "-qm", "initial"], cwd=self.repo, check=True)
        self.base = ai_native.work_snapshot(self.repo)["commit"]
        self.contract = {"schema_version": 1, "task_id": "task-one", "goal": "make feature",
                         "acceptance": "Unit tests and independent review", "base_commit": self.base,
                         "approved_paths": ["app.py", "src/**/*.py"], "forbidden_paths": ["src/secret.py"],
                         "gates": [{"id":"unit", "level":"unit", "command":[sys.executable,"-c","pass"]}]}

    def tearDown(self):
        self.temp.cleanup()

    def assertVerdict(self, expected):
        packet = self.repo / ".ai-native/runs/task-one/attempt-01"
        packet.mkdir(parents=True, exist_ok=True)
        snapshot = ai_native.work_snapshot(self.repo)
        contract_hash = governance.digest(self.contract)
        ai_native.save_json(packet / "gates.json", {"gates":[{"id":"unit","level":"unit","status":"PASS",
                                                               "source_fingerprint":snapshot["fingerprint"]}],
                                                    "source_fingerprint":snapshot["fingerprint"]})
        decision = control_plane.decide_cycle({
            "schema_version":1, "task_status":expected, "attempt":1, "max_attempts":3,
            "deadline_exceeded":False, "executor_configured":False, "executor_status":"PASS",
            "reviewer_configured":True, "reviewer_process_status":"PASS", "reviewer_verdict":expected,
            "reviewer_independent":True, "current_fingerprint":snapshot["fingerprint"],
            "reviewed_fingerprint":snapshot["fingerprint"], "contract_hash":contract_hash,
            "reviewed_contract_hash":contract_hash,
            "gates":[{"id":"unit","required":True,"status":"PASS","source_fingerprint":snapshot["fingerprint"]}],
            "gate_source_fingerprint":snapshot["fingerprint"]
        })
        ai_native.save_json(self.repo / ".ai-native/runs/task-one/latest.json",
                            {"task_id":"task-one", "attempt":1, "verdict": expected,
                             "contract_hash":contract_hash, "snapshot":snapshot,
                             "reviewed_fingerprint":snapshot["fingerprint"],
                             "reviewed_contract_hash":contract_hash,
                             "failed_required_gates":[], "control_plane_decision":decision})

    def test_approval_and_verified_exact_tip_eligible(self):
        governance.approve(self.repo, self.contract, "architect", "architect")
        self.assertVerdict("PASS")
        self.assertEqual(governance.eligibility(self.repo, self.contract), [])

    def test_executor_cannot_approve(self):
        with self.assertRaises(ValueError):
            governance.approve(self.repo, self.contract, "worker", "executor")

    def test_no_approval_blocks_merge(self):
        self.assertVerdict("PASS")
        self.assertIn("missing independent task approval", governance.eligibility(self.repo, self.contract))

    def test_mutated_contract_invalidates_approval(self):
        governance.approve(self.repo, self.contract, "planner", "planner")
        self.assertVerdict("PASS")
        self.contract["goal"] = "weakened contract"
        self.assertTrue(any("contract changed" in p for p in governance.eligibility(self.repo, self.contract)))

    def test_stale_review_blocks(self):
        governance.approve(self.repo, self.contract, "planner", "planner")
        self.assertVerdict("PASS")
        (self.repo / "app.py").write_text("changed\n", encoding="utf-8")
        problems = governance.eligibility(self.repo, self.contract)
        self.assertTrue(any("stale" in p for p in problems))

    def test_unapproved_path_blocks(self):
        (self.repo / "unrelated.txt").write_text("new\n")
        self.assertTrue(any("unrelated" in p for p in governance.scope_issues(self.repo, self.contract)))

    def test_forbidden_path_blocks(self):
        p = self.repo / "src/secret.py"
        p.parent.mkdir()
        p.write_text("secret\n")
        self.assertTrue(any("forbidden" in p for p in governance.scope_issues(self.repo, self.contract)))

    def test_governance_files_protected(self):
        (self.repo / "AGENTS.md").write_text("rewrite rules\n")
        self.assertTrue(any("protected" in p for p in governance.scope_issues(self.repo, self.contract)))

    def test_rename_source_is_not_hidden(self):
        (self.repo / "app.py").rename(self.repo / "new.txt")
        problems = governance.scope_issues(self.repo, self.contract)
        self.assertTrue(any("new.txt" in p for p in problems))

    def test_required_scope_blocks_laundering(self):
        governance.approve(self.repo, self.contract, "planner", "planner")
        self.assertVerdict("PASS")
        policy = {"schema_version": 1, "requirements":[{"id":"voice-session", "min_level":"device", "gate_ids":["unit"]}]}
        problems = governance.eligibility(self.repo, self.contract, policy)
        self.assertTrue(any("below required" in p for p in problems))

    def test_terminal_evidence_missing_blocks(self):
        governance.approve(self.repo, self.contract, "planner", "planner")
        self.assertVerdict("PASS")
        policy = {"schema_version": 1, "requirements":[{"id":"full-trip", "min_level":"unit", "gate_ids":["unit"],
                                   "terminal_required":True}]}
        self.assertTrue(any("terminal" in p for p in governance.eligibility(self.repo, self.contract, policy)))

    def test_device_cannot_be_substituted_by_visual_or_performance(self):
        self.assertFalse(governance.evidence_level_satisfies("performance", "device"))
        self.assertFalse(governance.evidence_level_satisfies("visual", "device"))
        self.assertTrue(governance.evidence_level_satisfies("integration", "unit"))

    def test_terminal_trace_must_be_real_bound_and_natural(self):
        import hashlib
        governance.approve(self.repo, self.contract, "planner", "planner")
        self.assertVerdict("PASS")
        snap = ai_native.work_snapshot(self.repo)["fingerprint"]
        trace = self.repo / "trace.json"
        trace.write_text(json.dumps({"observed_terminal":"ARRIVED", "ended_naturally":True,
                                     "source_fingerprint":snap}), encoding="utf-8")
        ref = {"path":"trace.json", "sha256":hashlib.sha256(trace.read_bytes()).hexdigest()}
        result = governance.verified_terminal_artifact(self.repo, ref, "ARRIVED", snap)
        self.assertIsNone(result)
        trace.write_text("{}", encoding="utf-8")
        self.assertIn("checksum", governance.verified_terminal_artifact(self.repo, ref, "ARRIVED", snap))

    def test_empty_independent_manifest_rejected(self):
        governance.approve(self.repo, self.contract, "planner", "planner")
        self.assertVerdict("PASS")
        problems = governance.eligibility(self.repo, self.contract, {"schema_version": 1, "requirements": []})
        self.assertTrue(any("nonempty" in p for p in problems))

    def test_requirement_manifest_is_protected(self):
        p = self.repo / "verification/requirements.json"
        p.parent.mkdir()
        p.write_text("{}")
        self.assertTrue(any("protected" in issue for issue in governance.scope_issues(self.repo, self.contract)))

    def test_globs_are_slash_aware(self):
        self.assertTrue(governance.patterns_match("src/sub/main.py", "src/**/*.py"))
        self.assertFalse(governance.patterns_match("src/sub/main.py", "src/*.py"))


if __name__ == "__main__":
    unittest.main()
