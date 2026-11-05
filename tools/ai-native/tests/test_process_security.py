"""Role boundaries must be enforced by data flow, not prompt instructions."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from process_security import child_environment, redact_argv, redact_text


class ProcessSecurityTests(unittest.TestCase):
    def setUp(self):
        self.parent = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": "/tmp/isolated-user",
            "OPENAI_API_KEY": "sk-proj-very-secret-executor-credential",
            "REVIEWER_SECRET": "independent-reviewer-token-123456",
            "UNRELATED_SECRET": "unrelated-secret-123456",
            "AI_NATIVE_EXECUTOR_MODEL": "cheap-model",
            "AI_NATIVE_REVIEWER_MODEL": "strong-model",
            "AI_NATIVE_EXECUTOR_ENV_ALLOWLIST": "OPENAI_API_KEY",
            "AI_NATIVE_REVIEWER_ENV_ALLOWLIST": "REVIEWER_SECRET",
        }

    def test_executor_receives_only_its_opt_in_credential(self):
        env = child_environment("executor", self.parent)
        self.assertEqual(env["OPENAI_API_KEY"], self.parent["OPENAI_API_KEY"])
        self.assertNotIn("REVIEWER_SECRET", env)
        self.assertNotIn("UNRELATED_SECRET", env)
        self.assertEqual(env["AI_NATIVE_EXECUTOR_MODEL"], "cheap-model")
        self.assertNotIn("AI_NATIVE_REVIEWER_MODEL", env)

    def test_reviewer_cannot_inherit_executor_credential(self):
        env = child_environment("reviewer", self.parent, {"AI_NATIVE_REVIEW_PACKET": "/tmp/packet"})
        self.assertNotIn("OPENAI_API_KEY", env)
        self.assertEqual(env["REVIEWER_SECRET"], self.parent["REVIEWER_SECRET"])
        self.assertEqual(env["AI_NATIVE_REVIEW_PACKET"], "/tmp/packet")

    def test_reviewer_home_can_be_separated(self):
        self.parent["AI_NATIVE_REVIEWER_HOME"] = "/tmp/independent-reviewer"
        env = child_environment("reviewer", self.parent)
        self.assertEqual(env["HOME"], "/tmp/independent-reviewer")
        self.assertEqual(env["USERPROFILE"], "/tmp/independent-reviewer")

    def test_gate_secrets_are_opt_in(self):
        env = child_environment("gate", self.parent, {"AI_NATIVE_TASK_ID": "test"})
        self.assertNotIn("OPENAI_API_KEY", env)
        self.assertNotIn("REVIEWER_SECRET", env)
        self.assertEqual(env["AI_NATIVE_TASK_ID"], "test")

    def test_invalid_allowlist_rejected(self):
        self.parent["AI_NATIVE_REVIEWER_ENV_ALLOWLIST"] = "OPENAI_API_KEY,*"
        with self.assertRaises(ValueError):
            child_environment("reviewer", self.parent)

    def test_protocol_fields_override_untrusted_parent(self):
        self.parent["AI_NATIVE_REVIEW_RESULT"] = "/tmp/evil"
        env = child_environment("reviewer", self.parent, {"AI_NATIVE_REVIEW_RESULT": "/tmp/good"})
        self.assertEqual(env["AI_NATIVE_REVIEW_RESULT"], "/tmp/good")

    def test_redacts_known_and_pattern_credentials(self):
        secret = self.parent["OPENAI_API_KEY"]
        message = "Bearer tokenabc password=hunter42 " + secret + " API_KEY=12345"
        cleaned = redact_text(message, self.parent)
        self.assertNotIn(secret, cleaned)
        self.assertNotIn("tokenabc", cleaned)
        self.assertNotIn("hunter42", cleaned)
        self.assertNotIn("12345", cleaned)
        self.assertIn("[REDACTED]", cleaned)

    def test_command_arguments_are_redacted(self):
        args = ["worker", "--key=" + self.parent["OPENAI_API_KEY"]]
        result = redact_argv(args, self.parent)
        self.assertNotIn(self.parent["OPENAI_API_KEY"], " ".join(result))
        self.assertEqual(args[0], result[0])

    def test_secret_value_after_flag_is_redacted(self):
        args = ["worker", "--api-key", "short-secret", "--password=hunter42",
                "--token", "token-value"]
        result = redact_argv(args, self.parent)
        self.assertEqual(result, ["worker", "--api-key", "[REDACTED]",
                                  "--password=[REDACTED]", "--token", "[REDACTED]"])


if __name__ == "__main__":
    unittest.main()
