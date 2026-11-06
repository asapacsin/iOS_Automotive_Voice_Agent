"""F-04b row 22 (T-013f): make_speaker_pack.sh refuses a wrong or missing model and writes nothing."""
import hashlib
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
NAME = "speaker/m.onnx"


class MakeSpeakerPackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        (self.tmp / "scripts/sherpa").mkdir(parents=True)
        (self.tmp / "scripts/speaker_pack").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/make_speaker_pack.sh", self.tmp / "scripts/")
        shutil.copy(ROOT / "scripts/speaker_pack/Manifest.json", self.tmp / "scripts/speaker_pack/")
        self.models = self.tmp / "models"
        (self.models / "speaker").mkdir(parents=True)
        (self.models / "speaker/speaker.json").write_text("{}")
        self.out = self.tmp / "out.aar"

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_script(self, model: bytes | None, pinned: bytes):
        if model is not None:
            (self.models / NAME).write_bytes(model)
        sha = hashlib.sha256(pinned).hexdigest()
        (self.tmp / "scripts/sherpa/models.sha256").write_text(f"{'0' * 64}  asr/x\n{sha}  {NAME}\n")
        return subprocess.run(["bash", str(self.tmp / "scripts/make_speaker_pack.sh"), str(self.models), str(self.out)],
                              capture_output=True, text=True)

    def test_missing_model_refused(self):
        r = self.run_script(None, b"model")
        self.assertEqual(r.returncode, 1)
        self.assertIn("missing", r.stderr)
        self.assertFalse(self.out.exists())

    def test_wrong_model_refused(self):
        r = self.run_script(b"other", b"model")
        self.assertEqual(r.returncode, 1)
        self.assertIn("sha256 mismatch", r.stderr)
        self.assertFalse(self.out.exists())

    def test_matching_model_passes_check(self):
        r = self.run_script(b"model", b"model")
        self.assertIn("sha256 ok", r.stdout)
        if shutil.which("xcrun") is None:
            self.assertEqual(r.returncode, 2)
            self.assertFalse(self.out.exists())

    def test_manifest_is_essential_pack_with_pinned_id(self):
        import json
        m = json.loads((ROOT / "scripts/speaker_pack/Manifest.json").read_text())
        self.assertEqual(m["assetPackID"], "speaker-campplus-v1")
        self.assertEqual(sorted(m["downloadPolicy"]["essential"]["installationEventTypes"]),
                         ["firstInstallation", "subsequentUpdate"])


if __name__ == "__main__":
    unittest.main()
