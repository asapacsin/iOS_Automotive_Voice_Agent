"""Unit tests for scripts/speaker_eval.py's scoring math (F-04b §5 item 5, §8 row 10). No model, no sherpa-onnx.

Run: python3 -m unittest discover -s scripts/gates/tests   (scripts/gates/run_all.sh does this)
"""
import contextlib
import io
import math
import pathlib
import shutil
import struct
import sys
import tempfile
import unittest
import wave

SCRIPTS = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SCRIPTS))

import speaker_eval as se  # noqa: E402


class MathTests(unittest.TestCase):
    def test_cosine(self):
        self.assertAlmostEqual(se.cosine([1, 0], [0, 1]), 0.0)
        self.assertAlmostEqual(se.cosine([1, 2], [2, 4]), 1.0)
        self.assertAlmostEqual(se.cosine([1, 0], [-1, 0]), -1.0)
        self.assertIsNone(se.cosine([1, 0], [1, 0, 0]))
        self.assertIsNone(se.cosine([0, 0], [1, 0]))
        self.assertIsNone(se.cosine([], []))

    def test_unit_average_normalises_each_then_the_sum(self):
        avg = se.unit_average([[10, 0], [0, 1]])   # unit vectors first, so the big one does not dominate
        self.assertAlmostEqual(avg[0], avg[1])
        self.assertAlmostEqual(math.hypot(*avg), 1.0)
        self.assertIsNone(se.unit_average([]))
        self.assertIsNone(se.unit_average([[1, 0], [1]]))
        self.assertIsNone(se.unit_average([[0, 0]]))
        self.assertIsNone(se.unit_average([[1, 0], [-1, 0]]))

    def test_split_enroll_takes_first_n_sorted(self):
        enroll, test = se.split_enroll({"a": ["a/3.wav", "a/1.wav", "a/2.wav"], "b": ["b/1.wav"]}, 1)
        self.assertEqual(enroll, {"a": ["a/1.wav"], "b": ["b/1.wav"]})
        self.assertEqual(test, {"a": ["a/2.wav", "a/3.wav"], "b": []})
        with self.assertRaises(ValueError):
            se.split_enroll({"a": ["a/1.wav"]}, 2)
        with self.assertRaises(ValueError):
            se.split_enroll({"a": ["a/1.wav"]}, 0)

    def test_trials_genuine_and_impostor(self):
        profiles = {"a": [1.0, 0.0], "b": [0.0, 1.0]}
        test = {"a": ["a2"], "b": ["b2", "b3"]}
        emb = {"a2": [1.0, 0.1], "b2": [0.1, 1.0], "b3": [1.0, 1.0]}
        trials = se.build_trials(profiles, test, emb)
        self.assertEqual(len(trials), 6)                       # 2 targets x 3 non-enrollment clips
        self.assertEqual(sum(t.genuine for t in trials), 3)    # a:a2, b:b2, b:b3
        imp = sorted((t.target, t.clip) for t in trials if not t.genuine)
        self.assertEqual(imp, [("a", "b2"), ("a", "b3"), ("b", "a2")])
        self.assertAlmostEqual(next(t.score for t in trials if (t.target, t.clip) == ("a", "b3")), math.sqrt(0.5))

    def test_counts_accept_at_or_above(self):
        self.assertEqual(se.counts_at([0.5, 0.49, 0.9], [0.5, 0.2], 0.5), (1, 1))

    def test_suggested_is_grid_point_strictly_above_max_impostor(self):
        self.assertAlmostEqual(se.suggested_threshold([0.1, 0.42]), 0.43)
        self.assertAlmostEqual(se.suggested_threshold([0.42]), 0.43)
        self.assertAlmostEqual(se.suggested_threshold([0.419]), 0.42)
        self.assertAlmostEqual(se.suggested_threshold([-0.05]), -0.04)
        self.assertIsNone(se.suggested_threshold([]))
        t = se.suggested_threshold([0.3, 0.61])
        self.assertEqual(se.counts_at([], [0.3, 0.61], t)[1], 0)

    def test_rows_cover_lowest_to_above_highest(self):
        rows = se.threshold_rows([0.8, 0.6], [0.31, 0.2])
        self.assertAlmostEqual(rows[0][0], 0.2)
        self.assertGreater(rows[-1][0], 0.8)
        self.assertEqual(rows[0][1:], (0, 2))
        self.assertEqual(rows[-1][1:], (2, 0))
        for (t1, *_), (t2, *_) in zip(rows, rows[1:]):
            self.assertAlmostEqual(t2 - t1, 0.01)

    def test_upper_bounds(self):
        self.assertAlmostEqual(se.upper_bound_zero(20), 1 - 0.05 ** (1 / 20))
        self.assertAlmostEqual(se.upper_bound_zero(20), 0.1391, places=4)    # §5 item 3: "about 14%"
        self.assertEqual(se.upper_bound_zero(0), 1.0)
        self.assertAlmostEqual(se.upper_bound(0, 20), se.upper_bound_zero(20))
        self.assertAlmostEqual(se.upper_bound(1, 20), 0.2161, places=3)      # Clopper-Pearson one-sided 95%
        self.assertEqual(se.upper_bound(5, 5), 1.0)

    def test_summary_and_report(self):
        trials = [se.Trial("a", "a", "a2", 0.7), se.Trial("a", "b", "b2", 0.3), se.Trial("b", "b", "b2", 0.6),
                  se.Trial("b", "a", "a2", 0.4)]
        s = se.summarize(trials, None)
        self.assertAlmostEqual(s["threshold"], 0.41)
        self.assertEqual(s["false_accepts"]["count"], 0)
        self.assertEqual(s["false_rejects"]["count"], 0)
        self.assertEqual(s["genuine"]["n"], 2)
        self.assertAlmostEqual(s["impostor"]["mean"], 0.35)
        self.assertEqual(s["per_target"]["a"], {"genuine_n": 1, "genuine_min": 0.7, "impostor_n": 1,
                                                "impostor_max": 0.3})
        given = se.summarize(trials, 0.65)
        self.assertEqual((given["false_rejects"]["count"], given["false_accepts"]["count"]), (1, 0))
        text = se.format_report(s, se.threshold_rows([0.7, 0.6], [0.3, 0.4]))
        self.assertIn("0 of 2", text)
        self.assertIn("threshold 0.41", text)


class WavTests(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.dir)

    def write(self, name, rate=16000, channels=1, samples=(0, 16384, -32768)):
        path = self.dir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(path), "wb") as w:
            w.setnchannels(channels)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(b"".join(struct.pack("<h", s) for s in samples for _ in range(channels)))
        return path

    def test_reads_16k_mono_and_truncates(self):
        self.assertEqual(se.read_wav(self.write("a.wav")), [0.0, 0.5, -1.0])
        self.assertEqual(len(se.read_wav(self.write("b.wav", samples=[0] * 32000), max_seconds=1.0)), 16000)

    def test_rejects_other_rates_and_stereo(self):
        with self.assertRaises(se.WavError):
            se.read_wav(self.write("c.wav", rate=8000))
        with self.assertRaises(se.WavError):
            se.read_wav(self.write("d.wav", channels=2))
        (self.dir / "e.wav").write_bytes(b"not a wav")
        with self.assertRaises(se.WavError):
            se.read_wav(self.dir / "e.wav")

    def test_list_clips_and_bad_input_exits_before_the_model(self):
        self.write("s1/1.wav")
        self.write("s1/2.WAV")
        self.write("s2/1.wav", rate=44100)
        (self.dir / "s2/readme.txt").write_text("x")
        self.assertEqual(se.list_clips(self.dir), {"s1": ["s1/1.wav", "s1/2.WAV"], "s2": ["s2/1.wav"]})
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = se.main(["--model", "/nonexistent.onnx", "--clips", str(self.dir), "--enroll", "1"])
        self.assertEqual(code, 2)
        self.assertIn("44100 Hz", err.getvalue())


if __name__ == "__main__":
    unittest.main()
