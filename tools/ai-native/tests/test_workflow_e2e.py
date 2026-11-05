"""Full local process orchestration using deliberately limited agent test doubles.

These tests verify the subprocess boundary and controller. They do NOT prove a
real paid model ran or that production CI/rulesets are installed.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / "scripts" / "ai_native.py"


class WorkflowEndToEndTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.repo = self.home / "project"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        (self.repo / ".gitignore").write_text(".ai-native/\n", encoding="utf-8")
        (self.repo / "app.py").write_text("value = 1\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "-qm", "initial"], cwd=self.repo, check=True)
        self.executor = self.home / "executor.py"
        self.reviewer = self.home / "reviewer.py"
        self.executor.write_text(
            "from pathlib import Path\n"
            "Path('app.py').write_text('value = 2\\n', encoding='utf-8')\n"
            "print('executor completed')\n", encoding="utf-8")
        self.reviewer.write_text(
            "import json, os\n"
            "from pathlib import Path\n"
            "packet=json.loads(Path(os.environ['AI_NATIVE_REVIEW_PACKET']).read_text())\n"
            "observed=Path('app.py').read_text()=='value = 2\\n'\n"
            "gates=all(g['status']=='PASS' for g in packet['gates'] if g.get('required',True))\n"
            "verdict='PASS' if observed and gates else 'REWORK'\n"
            "Path(os.environ['AI_NATIVE_REVIEW_RESULT']).write_text(json.dumps({"
            "'verdict': verdict,"
            "'reviewed_fingerprint': packet['snapshot']['fingerprint'],"
            "'reviewed_contract_hash': packet['contract_hash'],"
            "'findings': [],'next_action':'done'}))\n", encoding="utf-8")
        self.contract = self.home / "contract.json"
        self.contract.write_text(json.dumps({
            "schema_version": 1, "task_id": "e2e-smoke",
            "goal": "Change app value",
            "acceptance": "app.py has value = 2",
            "budgets": {"max_attempts": 1, "max_total_seconds": 30},
            "gates": [{"id": "app-value", "level": "unit", "required": True,
                       "command": [sys.executable, "-c",
                                   "from pathlib import Path; assert Path('app.py').read_text() == 'value = 2\\n'"]}]
        }), encoding="utf-8")

    def run_cycle(self, reviewer=None):
        return subprocess.run(
            [sys.executable, str(CONTROLLER), "cycle",
             "--repo", str(self.repo), "--contract", str(self.contract),
             "--executor", f'"{sys.executable}" "{self.executor}"',
             "--reviewer", f'"{sys.executable}" "{reviewer or self.reviewer}"'],
            cwd=ROOT, capture_output=True, text=True, timeout=45,
        )

    def latest(self):
        return json.loads((self.repo / ".ai-native/runs/e2e-smoke/latest.json").read_text())

    def test_executor_gate_external_reviewer_success(self):
        finished = self.run_cycle()
        self.assertEqual(finished.returncode, 0, finished.stdout + finished.stderr)
        report = self.latest()
        self.assertEqual(report["control_plane_decision"]["action"], "TASK_VERIFIED")
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual((self.repo / "app.py").read_text(), "value = 2\n")

    def test_reviewer_cannot_override_failed_requirement(self):
        self.executor.write_text("print('did not implement')\n", encoding="utf-8")
        finished = self.run_cycle()
        self.assertEqual(finished.returncode, 2, finished.stdout + finished.stderr)
        self.assertIn("app-value", self.latest()["failed_required_gates"])

    def test_wrong_reviewer_fingerprint_rejected(self):
        self.reviewer.write_text(
            "import json,os\n"
            "from pathlib import Path\n"
            "packet=json.loads(Path(os.environ['AI_NATIVE_REVIEW_PACKET']).read_text())\n"
            "Path(os.environ['AI_NATIVE_REVIEW_RESULT']).write_text(json.dumps({"
            "'verdict':'PASS','reviewed_fingerprint':'wrong',"
            "'reviewed_contract_hash':packet['contract_hash'],"
            "'findings':[],'next_action':'done'}))\n",
            encoding="utf-8")
        finished = self.run_cycle()
        self.assertEqual(finished.returncode, 4, finished.stdout + finished.stderr)
        self.assertEqual(self.latest()["verdict"], "NOT_VERIFIED")


if __name__ == "__main__":
    unittest.main()
