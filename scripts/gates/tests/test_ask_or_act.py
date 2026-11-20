import contextlib
import io
import json
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "eval"))
import ask_or_act as ev  # noqa: E402

RO = {"query_live_info", "web_search", "get_vehicle_state", "describe_camera_view", "google_search"}
EXPORT = {"search": {"instruction": "x", "tools": [{"name": "navigate_to", "description": "d", "parameters": {}}],
                     "notes": ["[系统] n"]},
          "readOnly": sorted(RO),
          "cases": [{"id": "sleepy-yes", "group": "askOrAct", "history": [],
                     "turns": [{"said": "有點困了", "expect": {"kind": "offer"}},
                               {"said": "好", "expect": {"kind": "act", "tools": ["navigate_to"]}}]}]}


def reply(text=None, call=None):
    parts = [{"text": text}] if text else []
    if call:
        parts.append({"functionCall": {"name": call, "args": {}}})
    return 200, {"candidates": [{"content": {"role": "model", "parts": parts}}]}


class AskOrActScriptTests(unittest.TestCase):
    def test_scorer_mirrors_swift_rules(self):
        """Same outcomes as AskOrActEvalTests in Swift (F-09b §14 row 3)."""
        act = {"kind": "act", "tools": ["navigate_to"]}
        self.assertIsNone(ev.score(act, ["navigate_to"], True, True, RO))          # pick question after options
        self.assertEqual(ev.score(act, ["navigate_to"], True, False, RO), "askedWhenDecided")
        self.assertEqual(ev.score(act, [], False, False, RO), "noTool")
        self.assertEqual(ev.score(act, ["play_music"], False, False, RO), "wrongTool")
        self.assertEqual(ev.score({"kind": "offer"}, ["control_climate"], True, False, RO), "actedBeforeAgreement")
        self.assertIsNone(ev.score({"kind": "offer"}, ["query_live_info"], True, False, RO))
        self.assertEqual(ev.score({"kind": "offer"}, [], False, False, RO), "noQuestion")
        self.assertEqual(ev.score({"kind": "answer"}, [], True, False, RO), "askedWhenDecided")
        self.assertIsNone(ev.score({"kind": "goes"}, ["make_trip_list"], False, False, RO))
        self.assertTrue(ev.asked("要不要去附近的咖啡店休息一下？") and not ev.asked("好的，已调低。"))

    def run_main(self, script, argv, ask=lambda p: "y"):
        calls = []

        def send(url, key, body):
            calls.append(body)
            return script[min(len(calls), len(script)) - 1]
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()) as out:
            src = pathlib.Path(tmp) / "e.json"
            src.write_text(json.dumps(EXPORT, ensure_ascii=False), encoding="utf-8")
            dst = pathlib.Path(tmp) / "o.json"
            code = ev.main([str(src), "--runs", "1", "--out", str(dst)] + argv, env={"GEMINI_API_KEY": "k"},
                           send=send, ask=ask)
            result = json.loads(dst.read_text(encoding="utf-8")) if dst.exists() else None
        return code, calls, result, out.getvalue()

    def test_two_turn_case_with_tool_round(self):
        script = [reply("要不要去附近的咖啡店休息一下？"), reply(call="navigate_to"), reply("屏幕上有三个，选哪个？")]
        code, calls, result, out = self.run_main(script, ["--yes"])
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 3)
        self.assertEqual(result["report"]["sleepy-yes"]["passed"], 1)
        self.assertIn("planned paid calls", out)
        # The functionResponse went back with the fake options.
        self.assertIn("functionResponse", json.dumps(calls[2]["contents"]))

    def test_asks_first_stops_at_max_calls_and_quota(self):
        code, calls, result, _ = self.run_main([reply("x")], [], ask=lambda p: "n")
        self.assertEqual((code, calls, result), (1, [], None))
        code, calls, result, _ = self.run_main([reply("要不要休息一下？")] * 9, ["--yes", "--max-calls", "1"])
        self.assertEqual(len(calls), 1)
        self.assertIn("--max-calls 1", result["stopped"])
        quota = (429, {"error": {"code": 429, "status": "quota_exceeded", "message": "You have exceeded your daily quota."}})
        code, calls, result, _ = self.run_main([quota], ["--yes"])
        self.assertEqual((len(calls), result["stopped"]), (1, "quota error"))

    def test_overload_is_retried_within_the_budget(self):
        ev.sleep = lambda s: None
        busy = (503, {"error": {"code": 503, "status": "UNAVAILABLE"}})
        code, calls, result, _ = self.run_main([busy, reply("要不要休息一下？"), reply(call="navigate_to"), reply("选哪个？")],
                                               ["--yes"])
        self.assertEqual(len(calls), 4)
        self.assertEqual(result["report"]["sleepy-yes"]["passed"], 1)


if __name__ == "__main__":
    unittest.main()
