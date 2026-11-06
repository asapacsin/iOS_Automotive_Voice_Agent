"""Actual Git remote integration checks; no network or model credentials needed."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from delivery_gate import check_delivery


def run_git(where, *args):
    return subprocess.run(["git", *args], cwd=where, check=True,
                          capture_output=True, text=True).stdout.strip()


class DeliveryGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.repo = self.parent / "work"
        self.remote = self.parent / "remote.git"
        self.repo.mkdir()
        run_git(self.parent, "init", "--bare", str(self.remote))
        run_git(self.repo, "init", "-b", "main")
        run_git(self.repo, "config", "user.name", "Test")
        run_git(self.repo, "config", "user.email", "test@example.invalid")
        (self.repo / ".gitignore").write_text(".ai-native/\n")
        (self.repo / "app.txt").write_text("first\n")
        run_git(self.repo, "add", ".")
        run_git(self.repo, "commit", "-m", "initial")
        run_git(self.repo, "remote", "add", "origin", str(self.remote))

    def test_requires_matching_remote_sha(self):
        self.assertEqual(check_delivery(self.repo)["status"], "NOT_VERIFIED")
        run_git(self.repo, "push", "-u", "origin", "main")
        self.assertEqual(check_delivery(self.repo)["status"], "PASS")
        (self.repo / "app.txt").write_text("second\n")
        self.assertEqual(check_delivery(self.repo)["status"], "NOT_VERIFIED")
        run_git(self.repo, "add", "app.txt")
        run_git(self.repo, "commit", "-m", "second")
        result = check_delivery(self.repo)
        self.assertEqual(result["status"], "NOT_VERIFIED")
        self.assertIn("remote SHA", result["reason"])
        run_git(self.repo, "push", "origin", "main")
        self.assertEqual(check_delivery(self.repo)["status"], "PASS")

    def test_no_fabricated_success_on_missing_remote_or_branch(self):
        self.assertEqual(check_delivery(self.repo, "not-configured")["status"], "NOT_VERIFIED")
        self.assertEqual(check_delivery(self.repo, branch="not-pushed")["status"], "NOT_VERIFIED")


if __name__ == "__main__":
    unittest.main()
