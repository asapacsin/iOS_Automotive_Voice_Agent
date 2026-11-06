"""T-020a F-07 §14 item 1: offline checks of scripts/tts_eval/qwen_tts_check.py (no key, no network)."""
import contextlib
import io
import json
import os
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tts_eval"))
import qwen_tts_check as q  # noqa: E402


class QwenTTSCheckTests(unittest.TestCase):
    def test_body_has_no_instruction(self):
        b = json.loads(q.body("好", "longanhuan_v3.1"))
        self.assertEqual(b, {"model": "qwen-audio-3.1-tts-flash",
                             "input": {"text": "好", "voice": "longanhuan_v3.1", "format": "pcm", "sample_rate": 24000}})

    def test_sse_joins_split_data_lines(self):
        p = q.SSE()
        self.assertEqual(p.feed(b'data:{"a"'), [])
        self.assertEqual(p.feed(b':1}\r\n\r\ndata:x'), ['{"a":1}'])
        self.assertEqual(p.finish(), ["x"])

    def test_worst_wait_against_playback(self):
        # 1 s of audio at t=0, the next piece at t=1.25 s: a 250 ms gap.
        self.assertAlmostEqual(q.worst_wait([(0.0, 48000), (1.25, 100)], 0.0), 250.0)
        self.assertEqual(q.worst_wait([(0.0, 48000), (0.5, 100)], 0.0), 0.0)

    def test_needs_env_and_never_prints_key(self):
        err = io.StringIO()
        with mock.patch.dict(os.environ, {"DASHSCOPE_API_KEY": "", "DASHSCOPE_API_HOST": ""}), contextlib.redirect_stderr(err):
            self.assertEqual(q.main([]), 2)
        self.assertIn("DASHSCOPE_API_KEY", err.getvalue())


if __name__ == "__main__":
    unittest.main()
