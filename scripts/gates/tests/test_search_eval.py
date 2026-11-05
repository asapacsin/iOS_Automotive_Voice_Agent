"""Unit tests for scripts/search_eval/run.py (F-18 §23 items 5-7, row 6). Mocked HTTP; no network, no key.

Run: python3 -m unittest discover -s scripts/gates/tests   (scripts/gates/run_all.sh does this)
"""
import contextlib
import datetime
import io
import json
import pathlib
import re
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "search_eval"))

import run as se  # noqa: E402

TODAY = datetime.date(2026, 11, 5)
ZONE = "Asia/Shanghai"
# Built from parts so no key-like literal is in the repo.
FAKE_KEY = "-".join(["test", "only", "search", "eval", "value"])
QUESTION = {"id": "w01", "query": "横琴后天天气怎么样", "words": "横琴后天天气怎么样"}


class PromptTests(unittest.TestCase):
    def test_freshprompt_exact(self):
        for setup in ("S1", "S2", "S3"):
            msgs = se.messages(setup, QUESTION, TODAY, ZONE)
            self.assertEqual(msgs, [
                {"role": "system", "text": "You are a helpful assistant. Answer as concisely as possible. Knowledge cutoff: November 05, 2026."},
                {"role": "user", "text": "What's today's date?"},
                {"role": "assistant", "text": "Today is November 05, 2026 in Asia/Shanghai."},
                {"role": "user", "text": "query: 横琴后天（2026年11月7日）天气怎么样\n\nquestion: 横琴后天天气怎么样\nanswer: "},
            ])

    def test_s0_is_the_app_system_text(self):
        swift = (ROOT / "Packages/NovaRealtime/Sources/NovaRealtime/Search/QwenWebSearchClient.swift").read_text(encoding="utf-8")
        literal = re.search(r'return "今天是\\\(date\)，\\\(weekdays\[[^\]]*\]\)，时区\\\(zone\.identifier\)。([^"]*)"', swift)
        self.assertIsNotNone(literal, "QwenWebSearchClient.instruction changed: copy it into run.py app_system")
        msgs = se.messages("S0", QUESTION, TODAY, ZONE)
        self.assertEqual(msgs[0], {"role": "system", "text": f"今天是2026年11月5日，星期四，时区{ZONE}。{literal.group(1)}"})
        self.assertEqual(len(msgs), 2)
        self.assertEqual(msgs[1]["role"], "user")

    def test_user_message_forms(self):
        self.assertEqual(se.user_message("q", "w"), "query: q\n\nquestion: w\nanswer: ")
        for none in (None, "", "  "):
            self.assertEqual(se.user_message("q", none), "question: q\nanswer: ")
        self.assertEqual(se.user_message("q", "雨" * 300), f"query: q\n\nquestion: {'雨' * 200}\nanswer: ")

    def test_date_rewrite(self):
        self.assertEqual(se.date_rewrite("上海大后天天气", TODAY), "上海大后天（2026年11月8日）天气")
        self.assertEqual(se.date_rewrite("今天油价", TODAY), "今天（2026年11月5日）油价")
        self.assertEqual(se.date_rewrite("美元汇率", TODAY), "美元汇率")
        self.assertEqual(se.date_rewrite("今天和明天", TODAY), "今天和明天")
        self.assertEqual(se.date_rewrite("11月7日后天", TODAY), "11月7日后天")

    def test_setup_requests(self):
        msgs = se.messages("S0", QUESTION, TODAY, ZONE)
        url, body, streamed = se.request("S0", msgs)
        self.assertEqual(url, se.MULTIMODAL)
        self.assertTrue(streamed)
        self.assertEqual(body["model"], "qwen3.7-flash")
        self.assertEqual(body["parameters"]["search_options"], {"search_strategy": "turbo", "enable_source": True, "forced_search": True})
        self.assertFalse(body["parameters"]["enable_thinking"])
        _, s1, _ = se.request("S1", se.messages("S1", QUESTION, TODAY, ZONE))
        self.assertEqual(s1["parameters"], body["parameters"])
        url, s2, streamed = se.request("S2", se.messages("S2", QUESTION, TODAY, ZONE))
        self.assertEqual((s2["model"], s2["search_options"]["search_strategy"], s2["enable_thinking"], s2["stream"], streamed),
                         ("qwen3.8-max", "agent_max", True, True, True))
        url, s3, streamed = se.request("S3", se.messages("S3", QUESTION, TODAY, ZONE))
        self.assertEqual(url, se.RESPONSES)
        self.assertEqual((s3["model"], s3["tools"], s3["enable_thinking"]),
                         ("qwen3.8-flash", [{"type": "web_search"}, {"type": "web_extractor"}], True))

    def test_questions_file(self):
        doc = json.loads((ROOT / "scripts/search_eval/questions.json").read_text(encoding="utf-8"))
        qs = doc["questions"]
        self.assertEqual(len(qs), 20)
        self.assertEqual(len({q["id"] for q in qs}), 20)
        for q in qs:
            self.assertEqual(q["reference"], "")
            self.assertTrue(q["reference_source"] and q["query"] and q["words"])
        self.assertEqual(sum(1 for q in qs if q["category"] == "follow_up"), 2)


STREAM = (
    'data: {"output":{"choices":[{"message":{"content":[{"text":"横琴11月7日小雨"}]}}],'
    '"search_info":{"search_results":[{"url":"https://www.nmc.cn/a","title":"t"}]}},'
    '"usage":{"total_tokens":321,"plugins":{"search":{"count":1}}}}\n'
)


class RunTests(unittest.TestCase):
    def test_key_never_written_or_printed_and_refusals_recorded(self):
        sent = []

        def post(url, headers, body, timeout):
            sent.append((url, headers, body))
            if url == se.RESPONSES:
                return 400, json.dumps({"error": {"code": "InvalidParameter", "message": "no"}}).encode()
            return 200, STREAM.encode()

        with tempfile.TemporaryDirectory() as tmp:
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = se.main(["--setups", "S0,S1,S3", "--runs", "3"], env={se.KEY_ENV: FAKE_KEY}, post=post,
                               out_dir=pathlib.Path(tmp))
            self.assertEqual(code, 0)
            files = {p.name: p.read_text(encoding="utf-8") for p in pathlib.Path(tmp).iterdir()}
            self.assertEqual(set(files), {"results.csv", "summary.csv"})
            for text in list(files.values()) + [out.getvalue(), err.getvalue()]:
                self.assertNotIn(FAKE_KEY, text)
            self.assertEqual(len(sent), 3 * 20 * 3)
            for url, headers, body in sent:
                self.assertEqual(headers["Authorization"], f"Bearer {FAKE_KEY}")
                self.assertNotIn(FAKE_KEY.encode(), body)
            rows = files["results.csv"].splitlines()
            self.assertEqual(rows[0], ",".join(se.RESULT_FIELDS))
            self.assertIn("InvalidParameter", files["results.csv"])
            self.assertIn("https://www.nmc.cn/a", files["results.csv"])
            summary = files["summary.csv"]
            self.assertIn("S0,qwen3.7-flash,60,0,0,60,60,0,0,", summary)
            self.assertIn("S3,qwen3.8-flash,60,0,0,0,0,60,0,", summary)
            self.assertIn("search_fee_only_usd_per_question", summary)
            s0 = next(r for r in se.summary([dict(r) for r in __import__("csv").DictReader(io.StringIO(files["results.csv"]))])
                      if r["setup"] == "S0")
            self.assertEqual(s0["search_fee_only_usd_per_question"], 0.01)  # 60 calls x $0.01 / 60 rows

    def test_missing_key(self):
        out, err = io.StringIO(), io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = se.main([], env={}, post=lambda *a: self.fail("sent without a key"), out_dir=pathlib.Path(tmp))
            self.assertEqual(list(pathlib.Path(tmp).iterdir()), [])
        self.assertEqual(code, 2)

    def test_network_error_records_class_only(self):
        def post(url, headers, body, timeout):
            raise TimeoutError(f"boom {headers['Authorization']}")

        with contextlib.redirect_stdout(io.StringIO()):
            rows = se.run(["S1"], [QUESTION], 1, TODAY, ZONE, FAKE_KEY, post=post)
        self.assertEqual((rows[0]["error_code"], rows[0]["network_error"]), ("", "TimeoutError"))
        self.assertEqual(se.summary(rows)[0]["network_errors"], 1)
        self.assertEqual(se.summary(rows)[0]["refused"], 0)
        self.assertNotIn(FAKE_KEY, json.dumps(rows, ensure_ascii=False))

    def test_search_counts_and_s2_note(self):
        s2 = ('data: {"choices":[{"delta":{"content":"小雨"}}]}\n'
              'data: {"choices":[],"usage":{"total_tokens":9,"x_tools":{"search":{"count":2}}}}\n').encode()
        p = se.parse("S2", s2)
        self.assertEqual((p["answer"], p["sources"], p["search_calls"], p["searched"]), ("小雨", "", 2, "yes"))
        s3 = json.dumps({"output": [{"type": "web_search_call"}, {"type": "web_search_call"},
                                    {"type": "message", "content": [{"type": "output_text", "text": "a"}]}]}).encode()
        self.assertEqual(se.parse("S3", s3)["search_calls"], 2)
        s3x = json.dumps({"output": [], "usage": {"x_tools": {"web_search": {"count": 3}}}}).encode()
        self.assertEqual(se.parse("S3", s3x)["search_calls"], 3)
        with contextlib.redirect_stdout(io.StringIO()):
            rows = se.run(["S2"], [QUESTION], 1, TODAY, ZONE, FAKE_KEY, post=lambda *a: (200, s2))
        self.assertIn("no sources", rows[0]["note"])
        self.assertIn("no sources", se.summary(rows)[0]["note"])

    def test_base_url(self):
        url, _, _ = se.request("S1", se.messages("S1", QUESTION, TODAY, ZONE), "https://ws.example.com/")
        self.assertEqual(url, "https://ws.example.com" + se.MULTIMODAL_PATH)
        seen = []
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            se.main(["--setups", "S3", "--runs", "1", "--base-url", "https://ws.example.com"], env={se.KEY_ENV: FAKE_KEY},
                    post=lambda u, h, b, t: (seen.append(u), (200, b"{}"))[1], out_dir=pathlib.Path(tmp))
        self.assertEqual(set(seen), {"https://ws.example.com" + se.RESPONSES_PATH})

    def test_partial_results_survive_a_crash(self):
        calls = []

        def post(url, headers, body, timeout):
            calls.append(1)
            if len(calls) == 3:
                raise KeyboardInterrupt
            return 200, STREAM.encode()

        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(KeyboardInterrupt):
                se.main(["--setups", "S1"], env={se.KEY_ENV: FAKE_KEY}, post=post, out_dir=pathlib.Path(tmp))
            lines = (pathlib.Path(tmp) / "results.csv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 3)  # header + the 2 rows done before the crash


if __name__ == "__main__":
    unittest.main()
