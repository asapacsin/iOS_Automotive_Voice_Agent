import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import codex_bridge as bridge


class CodexBridgeTests(unittest.TestCase):
    def test_executor_defaults_to_luna_medium_write(self):
        with patch.dict(os.environ, {}, clear=True):
            args = bridge.codex_command("executor", Path("/tmp/o"))
        self.assertEqual(args[args.index("--model") + 1], "gpt-6-luna")
        self.assertIn("model_reasoning_effort=medium", args)
        self.assertEqual(args[args.index("--sandbox") + 1], "workspace-write")

    def test_reviewer_defaults_to_astra_high_read_only(self):
        with patch.dict(os.environ, {}, clear=True):
            args = bridge.codex_command("reviewer", Path("/tmp/o"), Path("/tmp/s"))
        self.assertEqual(args[args.index("--model") + 1], "gpt-6-astra")
        self.assertIn("model_reasoning_effort=high", args)
        self.assertEqual(args[args.index("--sandbox") + 1], "read-only")
        self.assertIn("--output-schema", args)

    def test_reviewer_schema_requires_fingerprint_and_verdict(self):
        self.assertEqual(set(bridge.REVIEW_SCHEMA["required"]),
                         {"verdict", "reviewed_fingerprint", "reviewed_contract_hash", "findings", "next_action"})

    def test_review_prompt_avoids_self_review(self):
        content = bridge.role_prompt("reviewer", {"snapshot": {"fingerprint": "f00"}})
        self.assertIn("INDEPENDENT READ-ONLY", content)
        self.assertIn("git diff HEAD", content)

    def test_scoped_bridge_uses_read_only_schema_and_publishes_response(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            packet = root / "packet.json"
            output = root / "result.json"
            packet.write_text(json.dumps({"review_scope": {"mode": "diff_first"}}))

            def fake_codex(argv, *, input, text, timeout):
                self.assertEqual(argv[argv.index("--sandbox") + 1], "read-only")
                schema = json.loads(Path(argv[argv.index("--output-schema") + 1]).read_text())
                self.assertIn("review_scope", schema["required"])
                self.assertIn("Inspect all three diff commands", input)
                self.assertNotIn("git diff HEAD", input)
                temporary_output = Path(argv[argv.index("--output-last-message") + 1])
                self.assertNotEqual(temporary_output.parent, output.parent)
                temporary_output.write_text('{"verdict":"NOT_VERIFIED"}')
                return subprocess.CompletedProcess(argv, 0)

            env = {"AI_NATIVE_REVIEW_PACKET": str(packet), "AI_NATIVE_REVIEW_RESULT": str(output)}
            with patch.dict(os.environ, env), patch.object(bridge.shutil, "which", return_value="codex"), \
                 patch.object(bridge.subprocess, "run", side_effect=fake_codex):
                self.assertEqual(bridge.main(["reviewer"]), 0)
            self.assertEqual(json.loads(output.read_text()), {"verdict": "NOT_VERIFIED"})


if __name__ == "__main__":
    unittest.main()
