"""T-013j F-04b row 51: scripts/speaker_cohort.py on a tiny synthetic CN-Celeb-shaped set (speaker-lock.md §16 item 1).

No CN-Celeb, no model, no sherpa-onnx/soundfile: make_embedder and pinned_sha are faked from the test.
Run: python3 -m unittest discover -s scripts/gates/tests
"""
import contextlib
import hashlib
import io
import json
import pathlib
import shutil
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SCRIPTS))

try:
    import numpy as np
    import speaker_cohort as sc
except ImportError as exc:  # pragma: no cover
    np = sc = None
    SKIP = f"numpy not available ({exc}); speaker_cohort tests need numpy"
else:
    SKIP = None

DIM = 4
DEV = ["id00002", "id00001", "id00003"]  # unsorted on purpose
TEST = ["id00800", "id00801"]


def _vec(name):
    """Deterministic fake embedding keyed by speaker id (prefix before '-') plus a small per-file jitter."""
    spk = name.split("-")[0]
    base = np.random.default_rng(int(spk[2:])).normal(size=DIM)
    seed = int(hashlib.md5(name.encode()).hexdigest()[:8], 16)
    jitter = np.random.default_rng(seed).normal(size=DIM) * 0.1
    return (base + jitter).astype(np.float32)


def fake_make_embedder(model, threads):
    return (lambda p: _vec(pathlib.Path(p).stem)), DIM


@unittest.skipIf(SKIP, SKIP or "")
class SpeakerCohortMainTests(unittest.TestCase):
    """T-013j F-04b row 51: main() writes both files, or refuses and writes nothing."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        d = self.tmp / "CN-Celeb_flac"
        (d / "dev").mkdir(parents=True)
        (d / "dev" / "dev.lst").write_text("\n".join(DEV) + "\n")
        for s in DEV:
            (d / "data" / s).mkdir(parents=True)
            for k in range(2):
                (d / "data" / s / f"{s}-{k}.flac").write_bytes(b"x")
        ev = d / "eval"
        for sub in ("enroll", "test", "lists"):
            (ev / sub).mkdir(parents=True)
        for s in TEST:
            (ev / "enroll" / f"{s}-enroll.flac").write_bytes(b"x")
            (ev / "test" / f"{s}-t0.flac").write_bytes(b"x")
        lines = [f"{e}-enroll test/{t}-t0.flac {1 if e == t else 0}" for e in TEST for t in TEST]
        (ev / "lists" / "trials.lst").write_text("\n".join(lines) + "\n")
        self.data = d
        self.model = self.tmp / "model.onnx"
        self.model.write_bytes(b"fake model")
        self.sha = hashlib.sha256(b"fake model").hexdigest()
        self.out = self.tmp / "out"
        orig = (sc.make_embedder, sc.pinned_sha)
        self.addCleanup(lambda: (setattr(sc, "make_embedder", orig[0]), setattr(sc, "pinned_sha", orig[1])))
        sc.make_embedder = fake_make_embedder
        sc.pinned_sha = lambda: self.sha

    def run_main(self, *extra):
        argv = ["--data", str(self.data), "--model", str(self.model), "--out", str(self.out), *extra]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return sc.main(argv)

    def test_t013j_row51_writes_both_files(self):
        """T-013j F-04b row 51: cohort .f32 (sorted ids, LE float32) and .json with the item 1.3 fields."""
        self.assertEqual(self.run_main("--min-speakers", "3"), 0)
        raw = (self.out / "speaker_cohort.f32").read_bytes()
        self.assertEqual(len(raw), len(DEV) * DIM * 4)
        got = np.frombuffer(raw, dtype="<f4").reshape(len(DEV), DIM)
        want = np.stack([sc.speaker_mean(np.stack([_vec(f"{s}-{k}") for k in range(2)])) for s in sorted(DEV)])
        np.testing.assert_allclose(got, want, atol=1e-6)
        np.testing.assert_allclose(np.linalg.norm(got, axis=1), 1.0, atol=1e-6)
        meta = json.loads((self.out / "speaker_cohort.json").read_text())
        expect = {"source": "CN-Celeb1 dev (OpenSLR 82)", "license": "CC BY-SA 4.0", "model": sc.MODEL_NAME,
                  "modelSha256": self.sha, "speakers": 3, "dimension": DIM, "topN": 300, "trials": 4}
        for k, v in expect.items():
            self.assertEqual(meta[k], v, k)
        for k in ("threshold", "eer"):
            self.assertIsInstance(meta[k], float, k)
        self.assertTrue(0.0 <= meta["eer"] <= 1.0)
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ["speaker_cohort.f32", "speaker_cohort.json"])

    def test_top_n_as_given(self):
        self.assertEqual(self.run_main("--min-speakers", "3", "--top-n", "2"), 0)
        self.assertEqual(json.loads((self.out / "speaker_cohort.json").read_text())["topN"], 2)

    def test_wrong_sha_refuses_and_writes_nothing(self):
        sc.pinned_sha = lambda: "0" * 64
        self.assertEqual(self.run_main("--min-speakers", "3"), 1)
        self.assertFalse(self.out.exists())

    def test_too_few_speakers_refuses_and_writes_nothing(self):
        self.assertEqual(self.run_main("--min-speakers", "4"), 1)
        self.assertFalse(self.out.exists())

    def test_default_min_speakers_300_refuses(self):
        self.assertEqual(self.run_main(), 1)
        self.assertFalse(self.out.exists())


@unittest.skipIf(SKIP, SKIP or "")
class AsNormTests(unittest.TestCase):
    def test_as_norm_fixed_vectors(self):
        """T-013j F-04b row 51/52 parity value: the Swift SpeakerScoreNorm must give the same float."""
        cohort = sc.unit(np.array([[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [1, 1, 0, 0], [1, 0, 1, 1]],
                                  dtype=np.float64))
        e = np.array([1.0, 0, 0, 0])
        t = np.array([0.8, 0.6, 0, 0])
        self.assertAlmostEqual(float(sc.as_norm(e, t, cohort, 3)), 0.11945475087256302, delta=1e-7)


if __name__ == "__main__":
    unittest.main()
