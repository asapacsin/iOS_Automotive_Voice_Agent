"""Capability probes and input validation never silently claim GPU availability."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from capabilities import load_capabilities, missing_capabilities, probe_command, validate_capabilities
from frontier import check


class CapabilityTests(unittest.TestCase):
    def test_missing_capabilities_do_not_block_independent_work(self):
        available = {"nvidia_gpu": False, "ffmpeg": True}
        self.assertEqual(missing_capabilities({"requires": ["nvidia_gpu"]}, available),
                         ["nvidia_gpu"])
        self.assertEqual(missing_capabilities({"requires": ["ffmpeg"]}, available), [])
        self.assertEqual(missing_capabilities({}, available), [])

    def test_unobserved_capabilities_fail_closed(self):
        self.assertEqual(missing_capabilities({"requires": ["model_weights"]}, {}),
                         ["model_weights"])
        for value in ("true", 1, None):
            with self.assertRaises(ValueError):
                validate_capabilities({"schema_version": 1,
                                       "capabilities": {"nvidia_gpu": value}})

    def test_capabilities_load_from_trusted_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capabilities.json"
            path.write_text(json.dumps({"schema_version": 1,
                                        "capabilities": {"nvidia_gpu": False}}))
            self.assertEqual(load_capabilities(path), {"nvidia_gpu": False})

    def test_probe_reports_failure_or_missing_binary_as_unavailable(self):
        with patch("capabilities.shutil.which", return_value=None):
            self.assertFalse(probe_command("nvidia-smi", "-L"))
        with patch("capabilities.shutil.which", return_value="/usr/bin/nvidia-smi"):
            with patch("capabilities.subprocess.run", side_effect=subprocess.TimeoutExpired("gpu", 10)):
                self.assertFalse(probe_command("nvidia-smi", "-L"))

    def test_frontier_rejects_malformed_requires(self):
        task = {"id": "test", "owner": "AUTONOMOUS", "status": "NOT_RUN",
                "action": "run", "depends_on": [], "requires": ["gpu", "gpu"]}
        self.assertTrue(any("requires" in issue for issue in check(
            {"schema_version": 1, "work": [task]})))


if __name__ == "__main__":
    unittest.main()
