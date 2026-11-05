"""Exercise scoped review through real Git and the external reviewer protocol."""
import contextlib
import io
import json
import os
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import ai_native
from git_changes import git
from supervisor import verified_task

REVIEWER = """
import hashlib
import json
import os
import subprocess
from pathlib import Path

packet = json.loads(Path(os.environ["AI_NATIVE_REVIEW_PACKET"]).read_text())
scope = packet["review_scope"]
assert "AI_NATIVE_FEEDBACK" not in os.environ
assert "AI_NATIVE_CONTRACT" not in os.environ
trace = []
for name in ("committed", "staged", "unstaged"):
    entry = scope["diffs"][name]
    patch = subprocess.check_output(entry["argv"])
    assert hashlib.sha256(patch).hexdigest() == entry["sha256"]
    trace.append("diff:" + name)
for path, digest in scope["untracked"].items():
    source = Path(path)
    if digest.startswith("symlink:"):
        assert hashlib.sha256(os.fsencode(os.readlink(source))).hexdigest() == digest[8:]
    else:
        assert hashlib.sha256(source.read_bytes()).hexdigest() == digest
    trace.append("untracked:" + path)
for path, digest in scope["context_hashes"].items():
    assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest
    trace.append("context:" + path)

result = {
    "verdict": "PASS",
    "reviewed_fingerprint": packet["snapshot"]["fingerprint"],
    "reviewed_contract_hash": packet["contract_hash"],
    "findings": [], "next_action": "done",
    "review_scope": {
        "mode": scope["mode"], "manifest_hash": packet["review_scope_hash"],
        "initial_files": scope["initial_files"], "scope_complete": True,
        "additional_files": [], "expansion_reasons": [],
    }
}
"""


class ReviewScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        for path, content in {
            ".gitignore": ".ai-native/\n",
            "AGENTS.md": "Verify the call chain.\n",
            "build/tracked.py": "tracked = True\n",
            "scripts/service.py": "def calculate(): return 1\n",
            "scripts/AGENTS.md": "Preserve caller behavior.\n",
            "scripts/caller.py": "from service import calculate\nresult = calculate()\n",
            "tests/test_service.py": "assert True\n",
            "pyproject.toml": "[project]\nname = 'fixture'\n",
            "deleted.txt": "deleted\n",
            "old.txt": "renamed\n",
        }.items():
            self.write(path, content)
        self.git("add", ".")
        self.commit("base")
        self.contract = {
            "schema_version": 1, "task_id": "scope", "goal": "Update the service",
            "acceptance": "Callers continue to receive an integer.",
            "base_commit": self.git("rev-parse", "HEAD").decode().strip(),
            "review_scope": {},
            "gates": [{"id": "test", "level": "unit", "command": [sys.executable, "-c", "print('ok')"]}],
        }
        self.attempt = self.repo / ".ai-native/runs/scope/attempt-01"
        self.reviewer = self.root / "reviewer.py"
        self.trace = self.root / "trace.json"
        self.output = io.StringIO()
        self.set_reviewer()

    def git(self, *args):
        return git(self.repo, *args)

    def commit(self, message):
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", message)

    def write(self, path, content):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content, encoding="utf-8")
        return file

    def set_reviewer(self, body=""):
        self.reviewer.write_text(
            REVIEWER + textwrap.dedent(body) +
            f'\nPath({str(self.trace)!r}).write_text(json.dumps(trace))\n'
            'Path(os.environ["AI_NATIVE_REVIEW_RESULT"]).write_text(json.dumps(result))\n',
            encoding="utf-8",
        )

    def run_cycle(self, executor=None):
        contract_path = self.root / "contract.json"
        ai_native.save_json(contract_path, self.contract)
        args = ["cycle", "--repo", str(self.repo), "--contract", str(contract_path),
                "--reviewer", f'"{sys.executable}" "{self.reviewer}"']
        if executor:
            args.extend(["--executor", f'"{sys.executable}" "{executor}"'])
        with contextlib.redirect_stdout(self.output):
            code = ai_native.main(args)
        return code, ai_native.load_json(self.attempt.parent / "latest.json")

    def test_complete_inventory_and_diff_first_expansion(self):
        self.write("scripts/service.py", "def calculate(): return 2\n")
        self.git("mv", "old.txt", "renamed.txt")
        self.git("add", "scripts/service.py")
        self.commit("implement")
        self.write("build/tracked.py", "tracked = False\n")
        self.git("add", "build/tracked.py")
        # Cancel a staged edit in the worktree. A single diff to HEAD omits it.
        self.write("build/tracked.py", "tracked = True\n")
        self.git("rm", "deleted.txt")
        self.write("new.txt", "new source\n")
        self.write(".ai-native/device-result.json", '{"status":"ok"}\n')
        self.contract["review_scope"] = {
            "context_paths": [".ai-native/device-result.json"],
            "exclude_paths": ["build/**", "scripts/**", ".ai-native/**", "new.txt"],
        }
        self.set_reviewer("""
            assert "result = calculate()" in Path("scripts/caller.py").read_text()
            trace.append("expansion:scripts/caller.py")
            result["review_scope"]["additional_files"] = ["scripts/caller.py"]
            result["review_scope"]["expansion_reasons"] = ["Verify the caller's use of the integer result."]
        """)
        code, report = self.run_cycle()
        self.assertEqual(code, 0, report)
        scope = ai_native.load_json(self.attempt / "review_scope.json")
        self.assertEqual(scope["diffs"]["committed"]["files"], ["old.txt", "renamed.txt", "scripts/service.py"])
        self.assertEqual(scope["diffs"]["staged"]["files"], ["build/tracked.py", "deleted.txt"])
        self.assertEqual(scope["diffs"]["unstaged"]["files"], ["build/tracked.py"])
        changed = ["build/tracked.py", "deleted.txt", "new.txt", "old.txt", "renamed.txt", "scripts/service.py"]
        self.assertEqual(scope["changed_files"], changed)
        self.assertEqual(scope["initial_files"][:len(changed)], changed)
        self.assertEqual(scope["project_instructions"], ["AGENTS.md", "scripts/AGENTS.md"])
        self.assertIn("pyproject.toml", scope["initial_files"])
        self.assertIn("tests/test_service.py", scope["initial_files"])
        self.assertIn(".ai-native/device-result.json", scope["initial_files"])
        trace = json.loads(self.trace.read_text())
        self.assertEqual(trace[:4], ["diff:committed", "diff:staged", "diff:unstaged", "untracked:new.txt"])
        self.assertEqual(trace[-1], "expansion:scripts/caller.py")
        self.assertIn("Reviewer scope expansion:", self.output.getvalue())
        self.assertTrue(report["review_scope"]["scope_complete"])
        self.assertTrue(verified_task(self.repo, self.contract, "scope"))
        self.write(".ai-native/device-result.json", '{"status":"changed"}\n')
        self.assertFalse(verified_task(self.repo, self.contract, "scope"))

    def test_optional_expansion_logging_keeps_required_evidence(self):
        self.contract["review_scope"]["log_scope_expansions"] = False
        self.set_reviewer("""
            assert Path("scripts/caller.py").read_text()
            result["review_scope"]["additional_files"] = ["scripts/caller.py"]
            result["review_scope"]["expansion_reasons"] = ["Inspect integration."]
        """)
        code, report = self.run_cycle()
        self.assertEqual(code, 0, report)
        self.assertEqual(report["review_scope"]["additional_files"], ["scripts/caller.py"])
        self.assertNotIn("Reviewer scope expansion:", self.output.getvalue())

    def test_executor_cannot_narrow_scope_by_rewriting_copied_contract(self):
        executor = self.root / "executor.py"
        executor.write_text(textwrap.dedent("""
            import json, os
            from pathlib import Path
            path = Path(os.environ["AI_NATIVE_CONTRACT"])
            contract = json.loads(path.read_text())
            contract.pop("review_scope")
            path.write_text(json.dumps(contract))
            Path("scripts/service.py").write_text("def calculate(): return 2")
        """), encoding="utf-8")
        code, report = self.run_cycle(executor)
        self.assertEqual(code, 0, report)
        self.assertIn("scripts/service.py", report["review_scope"]["initial_files"])
        self.assertEqual(report["contract_hash"], ai_native.canonical_hash(self.contract))

    def test_missing_base_or_strict_policy_blocks_before_review(self):
        base = self.contract["base_commit"]
        for candidate, policy in [(None, "advisory"), ("HEAD", "advisory"),
                                  ("f" * 40, "advisory"), (base, "strict")]:
            with self.subTest(candidate=candidate, policy=policy):
                self.contract["base_commit"] = candidate
                self.contract["review_scope"]["read_policy"] = policy
                code, report = self.run_cycle()
                self.assertEqual((code, report["verdict"]), (4, "NOT_VERIFIED"))
                self.assertFalse(self.trace.exists())

    def test_invalid_scope_paths(self):
        for name in ("context_paths", "exclude_paths"):
            for path in ("/root", "../source", ".git/config", "a/../b", "C:secret", "a\\b", "a\0b"):
                with self.subTest(name=name, path=path):
                    self.contract["review_scope"] = {name: [path]}
                    with self.assertRaises(ValueError):
                        ai_native.validate_contract(self.contract)

    def test_missing_and_symlink_context_fail_closed(self):
        target = self.root / "outside.txt"
        target.write_text("must not read\n")
        (self.repo / "link").symlink_to(target)
        for path in ("absent", "link"):
            with self.subTest(path=path):
                self.contract["review_scope"]["context_paths"] = [path]
                code, report = self.run_cycle()
                self.assertEqual((code, report["verdict"]), (4, "NOT_VERIFIED"))
                self.assertFalse(self.trace.exists())

    def test_untracked_symlink_is_reviewed_as_metadata(self):
        (self.repo / "link").symlink_to(self.root / "missing")
        code, report = self.run_cycle()
        self.assertEqual(code, 0, report)
        self.assertIn("link", report["review_scope"]["initial_files"])
        self.assertIn("untracked:link", json.loads(self.trace.read_text()))

    def test_hidden_index_entry_fails_closed(self):
        self.git("update-index", "--assume-unchanged", "scripts/service.py")
        self.write("scripts/service.py", "def calculate(): return 9\n")
        code, report = self.run_cycle()
        self.assertEqual((code, report["verdict"]), (4, "NOT_VERIFIED"))
        self.assertIn("assume-unchanged", report["reason"])
        self.assertFalse(self.trace.exists())

    def test_omitted_files_wrong_scope_hash_and_disallowed_expansion_cannot_pass(self):
        self.write("scripts/service.py", "def calculate(): return 2\n")
        self.contract["review_scope"]["allow_scope_expansion"] = False
        for body in (
            'result["review_scope"]["initial_files"] = scope["initial_files"][1:]',
            'result["review_scope"]["manifest_hash"] = "stale"',
            'result["review_scope"].update(additional_files=["scripts/caller.py"], expansion_reasons=["caller"])',
        ):
            with self.subTest(body=body):
                self.set_reviewer(body)
                code, report = self.run_cycle()
                self.assertEqual((code, report["verdict"]), (4, "NOT_VERIFIED"))

    def test_not_verified_keeps_valid_partial_scope_evidence(self):
        self.set_reviewer("""
            result["verdict"] = "NOT_VERIFIED"
            result["review_scope"].update(scope_complete=False, initial_files=[])
            result["next_action"] = "Supply required integration evidence."
        """)
        code, report = self.run_cycle()
        self.assertEqual((code, report["verdict"]), (4, "NOT_VERIFIED"))
        self.assertFalse(report["review_scope"]["scope_complete"])
        self.assertIn("integration evidence", report["next_action"])

    def test_source_gate_evidence_and_staged_only_changes_invalidate_review(self):
        for body in (
            'Path("scripts/service.py").write_text("changed")',
            'Path(scope["gate_evidence"]).write_text("{}")',
            'subprocess.run(["git", "add", "scripts/service.py"], check=True)',
        ):
            with self.subTest(body=body):
                self.git("reset", "--hard", "HEAD")
                self.write("scripts/service.py", "def calculate(): return 2\n")
                self.set_reviewer(body)
                code, report = self.run_cycle()
                self.assertEqual((code, report["verdict"]), (4, "NOT_VERIFIED"))

    def test_stale_result_cannot_be_reused_when_reviewer_writes_nothing(self):
        code, report = self.run_cycle()
        self.assertEqual(code, 0, report)
        self.reviewer.write_text("pass\n")
        code, report = self.run_cycle()
        self.assertEqual((code, report["verdict"]), (4, "NOT_VERIFIED"))
        self.assertFalse((self.attempt / "review_result.json").exists())

    def test_failed_gate_still_overrides_scoped_reviewer_pass(self):
        self.contract["gates"][0]["command"] = [sys.executable, "-c", "raise SystemExit(1)"]
        code, report = self.run_cycle()
        self.assertEqual((code, report["verdict"]), (2, "REWORK"))
        self.assertEqual(report["failed_required_gates"], ["test"])
