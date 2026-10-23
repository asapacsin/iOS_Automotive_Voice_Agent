import os
import sys
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


if __name__ == "__main__":
    unittest.main()
