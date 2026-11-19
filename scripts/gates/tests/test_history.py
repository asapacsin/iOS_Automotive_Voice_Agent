"""specs/token-budget.md §4 row 7 (T-900f): scripts/history.py on a small copy of the registry."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HISTORY = ROOT / "scripts" / "history.py"
FRONTIER = ROOT / "tools" / "ai-native" / "scripts" / "frontier.py"

WORK = {"schema_version": 1, "work": [
    {"id": "T-001", "owner": "AUTONOMOUS", "status": "PASS", "priority": 1, "action": "old done", "depends_on": [],
     "evidence": ["gates"], "notes": "long " * 50},
    {"id": "T-002", "owner": "AUTONOMOUS", "status": "PASS", "priority": 1, "action": "done, others use it",
     "depends_on": ["T-001"], "evidence": ["gates"]},
    {"id": "T-003", "owner": "AUTONOMOUS", "status": "NOT_RUN", "priority": 1, "action": "open", "depends_on": ["T-002"]},
    {"id": "T-071a", "owner": "AUTONOMOUS", "status": "PASS", "priority": 1, "action": "a", "depends_on": [], "evidence": ["g"]},
    {"id": "T-071b", "owner": "AUTONOMOUS", "status": "PASS", "priority": 1, "action": "b", "depends_on": [], "evidence": ["g"]},
    {"id": "H-keys", "owner": "HUMAN_CREDENTIAL", "status": "NOT_APPLICABLE", "priority": 1, "action": "k", "depends_on": []},
]}
STATUS = ("# Implementation status\n\nOne line per task.\n\n| Date | Task | Result | Acceptance | Notes |\n|---|---|---|---|---|\n"
          "| 2026-10-01 | T-001 thing | PASS | x | none |\n"
          "| 2026-10-02 | T-001 and T-002 | PASS | x | none |\n"
          "| 2026-11-01 | T-002 thing | PASS | x | row 5 NOT_VERIFIED |\n"
          "| 2026-10-03 | T-071a-b camera | PASS | x | none |\n"
          "| 2026-10-04 | T-001 with H-keys | PASS | x | none |\n")


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.specs = Path(self.dir.name)
        (self.specs / "work.json").write_text(json.dumps(WORK, indent=2))
        (self.specs / "STATUS.md").write_text(STATUS)

    def tearDown(self):
        self.dir.cleanup()

    def run_history(self, *args):
        env = {**os.environ, "NOVA_HISTORY_SPECS": str(self.specs)}
        return subprocess.run([sys.executable, str(HISTORY), *args], capture_output=True, text=True, env=env)

    def decide(self, decisions):
        path = self.specs / "d.json"
        path.write_text(json.dumps(decisions))
        return self.run_history("apply", str(path))

    def test_row7_archive_leaves_stub_moves_rows_and_frontier_stays_valid(self):
        candidates = self.run_history("candidates").stdout
        self.assertIn("T-001 | PASS | 2026-10-04 | - |", candidates)
        self.assertIn("T-002 | PASS | 2026-11-01 | T-003 | yes |", candidates)
        self.assertFalse(any(l.startswith("T-003 ") for l in candidates.splitlines()))
        r = self.decide({"T-001": {"do": "archive", "reason": "done, nothing open needs it"},
                         "T-002": {"do": "keep", "reason": "T-003 depends on it"}})
        self.assertEqual(r.returncode, 0, r.stderr)
        work = json.loads((self.specs / "work.json").read_text())["work"]
        stub = work[0]
        self.assertTrue(stub["archived"])
        self.assertEqual((stub["id"], stub["status"], stub["depends_on"]), ("T-001", "PASS", []))
        archive = json.loads((self.specs / "work-archive.json").read_text())["archived"]
        self.assertEqual(archive[0]["notes"], WORK["work"][0]["notes"])
        self.assertEqual(archive[0]["archive_reason"], "done, nothing open needs it")
        status = (self.specs / "STATUS.md").read_text()
        moved = (self.specs / "STATUS-archive.md").read_text()
        self.assertIn("| 2026-10-01 | T-001 thing", moved)
        self.assertNotIn("T-001 thing", status)
        # A row also naming a kept id stays.
        self.assertIn("T-001 and T-002", status)
        self.assertIn("specs/STATUS-archive.md", status)
        self.assertEqual(self.run_history("check").returncode, 0)
        found = self.run_history("find", "T-001")
        self.assertEqual(found.returncode, 0)
        self.assertIn("old done", found.stdout)
        self.assertIn("T-001 thing", found.stdout)
        frontier = subprocess.run([sys.executable, str(FRONTIER), "check", "--registry", str(self.specs / "work.json")],
                                  capture_output=True, text=True)
        self.assertEqual(frontier.returncode, 0, frontier.stdout + frontier.stderr)

    def test_refusals_write_nothing(self):
        files = ("work.json", "STATUS.md")
        before = [(self.specs / f).read_text() for f in files]
        for decisions in ({"T-003": {"do": "archive", "reason": "x"}},
                          {"T-001": {"do": "archive", "reason": "ok"}, "T-003": {"do": "archive", "reason": "x"}},
                          {"T-001": "archive"},
                          {"T-002": {"do": "keep"}},
                          {"T-001": {"do": "archive"}},
                          {"T-404": {"do": "archive", "reason": "x"}},
                          {"T-001": {"do": "summarize", "reason": "x"}},
                          {"T-001": {"do": "drop", "reason": "x"}}):
            r = self.decide(decisions)
            self.assertNotEqual(r.returncode, 0, decisions)
            self.assertIn("refused", r.stderr)
        self.assertEqual([(self.specs / f).read_text() for f in files], before)
        self.assertFalse((self.specs / "work-archive.json").exists())
        self.assertFalse((self.specs / "STATUS-archive.md").exists())

    def test_letter_range_and_word_ids_hold_a_row_until_all_are_archived(self):
        r = self.decide({"T-071a": {"do": "archive", "reason": "done"}, "T-001": {"do": "archive", "reason": "done"}})
        self.assertEqual(r.returncode, 0, r.stderr)
        status = (self.specs / "STATUS.md").read_text()
        self.assertIn("T-071a-b camera", status)
        self.assertIn("T-001 with H-keys", status)
        self.assertEqual(self.run_history("check").returncode, 0)
        r = self.decide({"T-071b": {"do": "archive", "reason": "done"}, "H-keys": {"do": "archive", "reason": "withdrawn"}})
        self.assertEqual(r.returncode, 0, r.stderr)
        moved = (self.specs / "STATUS-archive.md").read_text()
        self.assertIn("T-071a-b camera", moved)
        self.assertIn("T-001 with H-keys", moved)
        self.assertIn("T-071a-b camera", self.run_history("find", "T-071b").stdout)
        self.assertEqual(self.run_history("check").returncode, 0)

    def test_summarize_keeps_item_and_full_text(self):
        r = self.decide({"T-001": {"do": "summarize", "notes": "short", "reason": "notes too long"}})
        self.assertEqual(r.returncode, 0, r.stderr)
        work = json.loads((self.specs / "work.json").read_text())["work"]
        self.assertEqual(work[0]["notes"], "short")
        self.assertFalse(work[0].get("archived", False))
        archive = json.loads((self.specs / "work-archive.json").read_text())["archived"]
        self.assertTrue(archive[0]["summarized"])
        self.assertEqual(archive[0]["notes"], WORK["work"][0]["notes"])
        self.assertEqual(self.run_history("check").returncode, 0)

    def test_check_fails_on_stub_without_archive_and_on_duplicates(self):
        work = json.loads((self.specs / "work.json").read_text())
        work["work"][0]["archived"] = True
        (self.specs / "work.json").write_text(json.dumps(work))
        self.assertEqual(self.run_history("check").returncode, 1)
        work["work"][0]["archived"] = False
        (self.specs / "work.json").write_text(json.dumps(work))
        (self.specs / "work-archive.json").write_text(json.dumps({"archived": [WORK["work"][0]]}))
        self.assertEqual(self.run_history("check").returncode, 1)
        # Archived twice, and archived with its stub gone.
        work["work"][0] = {"id": "T-001", "owner": "AUTONOMOUS", "status": "PASS", "action": "archived",
                           "depends_on": [], "archived": True, "evidence": ["w"]}
        (self.specs / "work.json").write_text(json.dumps(work))
        (self.specs / "work-archive.json").write_text(json.dumps({"archived": [WORK["work"][0]] * 2}))
        self.assertIn("more than once", self.run_history("check").stderr)
        del work["work"][0]
        (self.specs / "work.json").write_text(json.dumps(work))
        (self.specs / "work-archive.json").write_text(json.dumps({"archived": [WORK["work"][0]]}))
        self.assertIn("without a stub", self.run_history("check").stderr)

    def test_hook_never_errors(self):
        (self.specs / "STATUS.md").unlink()
        r = self.run_history("status", "--hook")
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))

    def test_status_hook_line_only_when_over(self):
        self.assertEqual(self.run_history("status", "--hook").stdout, "")
        (self.specs / "STATUS.md").write_text(STATUS + "| 2026-11-02 | T-9 | x | x | " + "y" * 90_000 + " |\n")
        line = self.run_history("status", "--hook").stdout
        self.assertIn("history large: STATUS.md", line)
        self.assertIn("scripts/history.py candidates", line)

    def test_live_registry_passes_check(self):
        r = subprocess.run([sys.executable, str(HISTORY), "check"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
