import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import discover_work


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        (self.repo / ".gitignore").write_text(".ai-native/\n", encoding="utf-8")
        self.source = self.repo / "OPEN_PROBLEMS.md"
        self.source.write_text(
            "# Work\n- [ ] Fix navigation timeout\n- [x] Add wake word\n"
            "1. [ ] Verify interruption behavior\n- [ ]   Keep   exact   scope  \n",
            encoding="utf-8"
        )
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "-qm", "initial"], cwd=self.repo, check=True)

    def test_only_explicit_unchecked_checkboxes_become_candidates(self):
        result = discover_work.discover(self.repo, ["OPEN_PROBLEMS.md"])
        self.assertEqual(result["candidate_count"], 3)
        self.assertEqual([x["title"] for x in result["candidates"]], [
            "Fix navigation timeout", "Verify interruption behavior", "Keep exact scope"
        ])
        self.assertTrue(all(x["status"] == "NEEDS_REVIEW" for x in result["candidates"]))
        self.assertEqual(result["sources"][0]["path"], "OPEN_PROBLEMS.md")
        self.assertEqual(result["candidates"][0]["source_sha256"],
                         hashlib.sha256(self.source.read_bytes()).hexdigest())

    def test_candidate_id_is_deterministic(self):
        a = discover_work.discover(self.repo, ["OPEN_PROBLEMS.md"])
        b = discover_work.discover(self.repo, ["OPEN_PROBLEMS.md"])
        self.assertEqual([x["id"] for x in a["candidates"]], [x["id"] for x in b["candidates"]])

    def test_duplicate_source_is_not_duplicated(self):
        result = discover_work.discover(self.repo, ["OPEN_PROBLEMS.md", "./OPEN_PROBLEMS.md"])
        self.assertEqual(result["candidate_count"], 3)
        self.assertEqual(len(result["sources"]), 1)

    def test_path_escape_rejected(self):
        outside = self.repo.parent / (self.repo.name + "-outside.md")
        outside.write_text("- [ ] external task\n", encoding="utf-8")
        self.addCleanup(lambda: outside.unlink(missing_ok=True))
        with self.assertRaises(ValueError):
            discover_work.discover(self.repo, [str(outside)])

    def test_runtime_state_cannot_be_a_source(self):
        runtime = self.repo / ".ai-native/candidates.md"
        runtime.parent.mkdir()
        runtime.write_text("- [ ] recursive generated task\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            discover_work.discover(self.repo, [".ai-native/candidates.md"])

    def test_unsupported_source_type_rejected(self):
        data = self.repo / "source.json"
        data.write_text('{"tasks":[]}', encoding="utf-8")
        with self.assertRaises(ValueError):
            discover_work.discover(self.repo, ["source.json"])

    def test_candidate_budget_is_fail_closed(self):
        with self.assertRaises(ValueError):
            discover_work.discover(self.repo, ["OPEN_PROBLEMS.md"], max_items=2)

    def test_output_must_be_ignored_when_inside_repo(self):
        with self.assertRaises(ValueError):
            discover_work.safe_output_path(self.repo, "candidates.json")
        path = discover_work.safe_output_path(self.repo, ".ai-native/candidates.json")
        self.assertEqual(path, (self.repo / ".ai-native/candidates.json").resolve())


if __name__ == "__main__":
    unittest.main()
