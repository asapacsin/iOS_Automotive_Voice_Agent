"""Supervisor behavioral tests: real subprocess calls with fake agent clients."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from supervisor import reconcile_interrupted, reconcile_capability_blockers
from governance import release_evidence_issues
from ai_native import work_snapshot

SUPERVISOR = ROOT / "scripts" / "supervisor.py"


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        (self.repo / ".gitignore").write_text(".ai-native/\n", encoding="utf-8")
        (self.repo / "app.py").write_text("value = 1\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "-qm", "init"], cwd=self.repo, check=True)

        self.contract = self.base / "task.json"
        self.contract.write_text(json.dumps({
            "schema_version": 1, "task_id": "change",
            "goal": "change value", "acceptance": "value = 2 and reviewed",
            "budgets": {"max_attempts": 1, "max_total_seconds": 30},
            "gates": [{"id": "value", "required": True, "level": "unit",
                       "command": [sys.executable, "-c",
                                   "from pathlib import Path; assert Path('app.py').read_text()=='value = 2\\n'"]}]
        }), encoding="utf-8")

        self.registry = self.base / "work.json"
        self.item = {"id": "change", "owner": "AUTONOMOUS", "status": "NOT_RUN",
                     "action": "Change app value", "depends_on": [],
                     "contract_path": str(self.contract)}
        self.save_registry()

        self.executor = self.base / "executor.py"
        self.executor.write_text(
            "from pathlib import Path\nPath('app.py').write_text('value = 2\\n')\n",
            encoding="utf-8")
        self.reviewer = self.base / "reviewer.py"
        self.reviewer.write_text(
            "import json,os\nfrom pathlib import Path\n"
            "p=json.loads(Path(os.environ['AI_NATIVE_REVIEW_PACKET']).read_text())\n"
            "passed=all(g['status']=='PASS' for g in p['gates'] if g.get('required', True))\n"
            "Path(os.environ['AI_NATIVE_REVIEW_RESULT']).write_text(json.dumps({"
            "'verdict':'PASS' if passed else 'REWORK',"
            "'reviewed_fingerprint':p['snapshot']['fingerprint'],"
            "'reviewed_contract_hash':p['contract_hash'],"
            "'findings':[],'next_action':'done'}))\n",
            encoding="utf-8")

    def save_registry(self):
        self.registry.write_text(json.dumps({"schema_version": 1, "work": [self.item]}), encoding="utf-8")

    def drive(self, extra_args=None):
        env = os.environ.copy()
        env["AI_NATIVE_EXECUTOR_CMD"] = f'"{sys.executable}" "{self.executor}"'
        env["AI_NATIVE_REVIEWER_CMD"] = f'"{sys.executable}" "{self.reviewer}"'
        return subprocess.run(
            [sys.executable, str(SUPERVISOR), "--repo", str(self.repo),
             "--registry", str(self.registry), "--max-tasks", "3", "--max-seconds", "60",
             *(extra_args or [])],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=70)

    def test_drives_verified_task_to_terminal_state(self):
        process = self.drive()
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        item = json.loads(self.registry.read_text())["work"][0]
        self.assertEqual(item["status"], "PASS")
        self.assertTrue(item["evidence"])
        self.assertIsInstance(item["evidence"][0], dict)
        proof_path = self.repo / item["evidence"][0]["path"]
        proof = json.loads(proof_path.read_text(encoding="utf-8"))
        self.assertEqual(item["contract_hash"], proof["contract_hash"])
        self.assertEqual(proof["task_id"], item["id"])
        self.assertTrue((self.repo / proof["report_path"]).is_file())
        registry = json.loads(self.registry.read_text())
        source = work_snapshot(self.repo)["fingerprint"]
        self.assertEqual(release_evidence_issues(self.repo, registry, source), [])
        (self.repo / "app.py").write_text("value = 3\n", encoding="utf-8")
        self.assertTrue(release_evidence_issues(self.repo, registry,
                        work_snapshot(self.repo)["fingerprint"]))
        self.assertEqual(json.loads((self.repo / ".ai-native/supervisor-checkpoint.json").read_text())["state"], "VERIFIED")

    def test_missing_contract_stops_without_inventing_execution(self):
        self.item["contract_path"] = "missing.json"
        self.save_registry()
        process = self.drive()
        self.assertEqual(process.returncode, 3, process.stdout + process.stderr)
        item = json.loads(self.registry.read_text())["work"][0]
        self.assertEqual(item["status"], "BLOCKED_EXTERNAL")

    def test_interrupted_run_without_evidence_remains_blocked(self):
        self.item["status"] = "RUNNING"
        self.save_registry()
        data = json.loads(self.registry.read_text())
        reconcile_interrupted(self.repo, self.registry, data)
        after = json.loads(self.registry.read_text())["work"][0]
        self.assertEqual(after["status"], "BLOCKED_EXTERNAL")
        self.assertIn("interrupted", after["blocked_by"])

    def test_missing_gpu_blocks_only_gpu_task_and_runs_independent_cpu_work(self):
        gpu = {"id": "gpu-e2e", "owner": "AUTONOMOUS", "status": "NOT_RUN",
               "action": "Run actual GPU inference", "depends_on": [],
               "requires": ["nvidia_gpu", "model_weights"], "priority": 1}
        self.item["priority"] = 2
        self.registry.write_text(json.dumps({"schema_version": 1,
                                             "work": [gpu, self.item]}), encoding="utf-8")
        capabilities = self.base / "capabilities.json"
        capabilities.write_text(json.dumps({"schema_version": 1, "capabilities": {
            "nvidia_gpu": False, "model_weights": False, "ffmpeg": True}}), encoding="utf-8")
        result = self.drive(["--capabilities", str(capabilities)])
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        tasks = {entry["id"]: entry for entry in json.loads(self.registry.read_text())["work"]}
        self.assertEqual(tasks["change"]["status"], "PASS")
        self.assertEqual(tasks["gpu-e2e"]["status"], "BLOCKED_EXTERNAL")
        self.assertEqual(tasks["gpu-e2e"]["blocker_kind"], "capability")
        self.assertEqual(tasks["gpu-e2e"]["blocked_capabilities"],
                         ["model_weights", "nvidia_gpu"])
        self.assertIn("WAIT_EXTERNAL", result.stdout)

        # A later B200 environment may requeue this task without altering CPU evidence.
        current = json.loads(self.registry.read_text())
        reconcile_capability_blockers(self.registry, current,
                                      {"nvidia_gpu": True, "model_weights": True})
        updated = {entry["id"]: entry for entry in json.loads(self.registry.read_text())["work"]}
        self.assertEqual(updated["gpu-e2e"]["status"], "NOT_RUN")
        self.assertNotIn("blocked_by", updated["gpu-e2e"])
        self.assertEqual(updated["change"]["status"], "PASS")

    def test_capability_gate_does_not_clear_unrelated_external_blockers(self):
        self.item["status"] = "BLOCKED_EXTERNAL"
        self.item["blocked_by"] = "credential approval required"
        self.item["requires"] = ["nvidia_gpu"]
        self.save_registry()
        reconcile_capability_blockers(self.registry, json.loads(self.registry.read_text()),
                                      {"nvidia_gpu": True})
        updated = json.loads(self.registry.read_text())["work"][0]
        self.assertEqual(updated["status"], "BLOCKED_EXTERNAL")
        self.assertEqual(updated["blocked_by"], "credential approval required")

    def test_require_remote_rejects_local_only_success(self):
        result = self.drive(["--require-remote"])
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        updated = json.loads(self.registry.read_text())["work"][0]
        self.assertEqual(updated["status"], "BLOCKED_EXTERNAL")
        self.assertEqual(updated["blocker_kind"], "delivery")
        self.assertIn("remote delivery", updated["blocked_by"])

    def test_rejects_tracked_mutable_registry(self):
        tracked = self.repo / "verification/work.json"
        tracked.parent.mkdir()
        tracked.write_text(self.registry.read_text(), encoding="utf-8")
        subprocess.run(["git", "add", "verification/work.json"], cwd=self.repo, check=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "-qm", "track work manifest"], cwd=self.repo, check=True)
        process = subprocess.run(
            [sys.executable, str(SUPERVISOR), "--repo", str(self.repo),
             "--registry", str(tracked), "--max-tasks", "1"],
            cwd=ROOT, capture_output=True, text=True, timeout=10)
        self.assertEqual(process.returncode, 5)
        self.assertIn("tracked", process.stderr)

    def test_dead_process_lock_is_reclaimed(self):
        lock = self.repo / ".ai-native/supervisor.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("99999999")
        result = self.drive()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(lock.exists())

    def test_concurrent_lock_rejected(self):
        lock = self.repo / ".ai-native/supervisor.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text(str(os.getpid()))
        process = self.drive()
        self.assertEqual(process.returncode, 5)
        self.assertTrue(lock.exists())


if __name__ == "__main__":
    unittest.main()
