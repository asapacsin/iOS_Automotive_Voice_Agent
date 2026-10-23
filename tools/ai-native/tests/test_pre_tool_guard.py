"""Unit tests for deterministic pre-tool scope enforcement."""
import tempfile
import unittest
from pathlib import Path

from scripts.pre_tool_guard import _valid_patterns, guard_event


class PreToolGuardTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp()).resolve()
        self.contract = {
            "approved_paths": ["src/**", "tests/**", "README.md"],
            "forbidden_paths": ["src/secrets/**"],
        }

    def guard(self, tool_name, tool_input):
        return guard_event(
            {"tool_name": tool_name, "tool_input": tool_input},
            self.repo,
            self.contract,
        )

    def test_allows_file_inside_approved_scope(self):
        self.assertIsNone(self.guard("Edit", {"file_path": "src/main.py"}))

    def test_blocks_file_outside_approved_scope(self):
        reason = self.guard("Write", {"file_path": "docs/private.md"})
        self.assertIn("outside approved_paths", reason)

    def test_forbidden_paths_override_approved_paths(self):
        self.contract["approved_paths"] = ["src/**"]
        reason = self.guard("Edit", {"file_path": "src/secrets/token.txt"})
        self.assertIn("forbidden_paths", reason)

    def test_protects_agent_instructions_even_if_approved(self):
        self.contract["approved_paths"] = ["**"]
        reason = self.guard("Write", {"file_path": "AGENTS.md"})
        self.assertIn("protected", reason)

    def test_blocks_path_escape_outside_repository(self):
        reason = self.guard("Edit", {"file_path": "../outside.py"})
        self.assertIn("outside the project", reason)

    def test_single_star_does_not_cross_directory_boundary(self):
        self.contract["approved_paths"] = ["src/*.py"]
        self.assertIsNone(self.guard("Edit", {"file_path": "src/main.py"}))
        reason = self.guard("Edit", {"file_path": "src/sub/main.py"})
        self.assertIn("outside approved_paths", reason)

    def test_double_star_recurses_across_directories(self):
        self.contract["approved_paths"] = ["src/**/*.py"]
        self.assertIsNone(self.guard("Edit", {"file_path": "src/sub/main.py"}))

    def test_blocks_force_reset(self):
        reason = self.guard("Bash", {"command": "git reset --hard HEAD"})
        self.assertIn("discard uncommitted work", reason)

    def test_blocks_recursive_forced_delete(self):
        reason = self.guard("Bash", {"command": "rm -rf build/"})
        self.assertIn("recursive forced deletion", reason)

    def test_allows_ordinary_test_command(self):
        self.assertIsNone(self.guard("Bash", {"command": "python3 -m unittest discover -s tests -v"}))

    def test_missing_approved_paths_fails_closed(self):
        reason = _valid_patterns({"gates": []})
        self.assertIn("approved_paths", reason)


if __name__ == "__main__":
    unittest.main()
