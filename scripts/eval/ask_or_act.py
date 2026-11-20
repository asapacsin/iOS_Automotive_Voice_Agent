#!/usr/bin/env python3
"""F-09b §14 item 5: AskOrActEval and the complaint set against Gemini with the app's real instruction and tools.

Input: the JSON written by EvalExportTests (EVAL_EXPORT=<file> swift test --filter EvalExportTests): instruction,
tools and session-start notes per setting, the cases with their expected behaviour. The driver's turns are
scripted; tool calls get fixed fake results (FAKE below); scoring is by behaviour only, the same rules as
`AskOrActEval.score` in Swift: a tool called or not, the right tool, nothing acting before agreement where the driver
had not decided, a question only where the driver had not decided.

Model: `--model gemini-3.8-flash` through generateContent (text). The app's model is gemini-3.8-live over a
websocket; this script does not drive it, so its numbers are a check of the instruction on another model, not the
§14 item 5 stage gate.

Paid calls (F-18 §32 item 6): prints the planned call count, starts only with --yes or a typed y, stops at
--max-calls and at the first quota error. Key: GEMINI_API_KEY, sent only in the x-goog-api-key header.
"""
import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

HOST = "https://generativelanguage.googleapis.com"
QUOTA = ("quota_exceeded", "exceeded your daily quota")
MAX_TOOL_ROUNDS = 4
RETRIES = 3
WAIT = [3, 10]
sleep = time.sleep

# Fixed results for the tools the cases reach; anything else gets {"ok": true}.
FAKE = {
    "navigate_to": {"ok": True, "options": [{"index": 1, "name": "瑞幸咖啡(香洲店)", "km": 1.2},
                                            {"index": 2, "name": "星巴克(拱北店)", "km": 2.5},
                                            {"index": 3, "name": "麦咖啡(吉大店)", "km": 3.1}],
                    "next": "屏幕上列出了候选地点，等司机选。"},
    "choose_navigation_option": {"ok": True, "navigating": True, "destination": "中石油前山站"},
    "control_climate": {"ok": True, "temperature": 22, "power": "on"},
    "make_trip_list": {"ok": True, "days": 3, "stops": 9},
    "query_live_info": {"ok": True, "address": "广东省珠海市香洲区", "time": "14:30", "date": "2026-11-20"},
    "web_search": {"ok": True, "answer": "（搜索结果）", "sources": ["example.com"]},
    "get_vehicle_state": {"ok": True, "temperature": 24, "acOn": True},
}
PICKING = {"navigate_to"}


def asked(text: str) -> bool:
    """The runner's rule: her reply's last sentence ends in a question mark."""
    t = text.strip().rstrip("」\"'）) ")
    return t.endswith("？") or t.endswith("?")


def score(expect: dict, tools: list, was_asked: bool, picking: bool, read_only: set) -> str | None:
    """Mirror of AskOrActEval.score (claims are not checked here: no claim guard in this runner)."""
    acting = [t for t in tools if t not in read_only]
    kind = expect["kind"]
    if kind == "act":
        wanted = set(expect.get("tools") or [])
        called = acting if not wanted else [t for t in tools if t in wanted]
        if not called:
            return "noTool" if not tools else "wrongTool"
        if was_asked and not picking:
            return "askedWhenDecided"
    elif kind == "offer":
        if acting:
            return "actedBeforeAgreement"
        if not was_asked:
            return "noQuestion"
    elif kind == "answer":
        if acting:
            return "actedBeforeAgreement"
        if was_asked:
            return "askedWhenDecided"
    elif kind == "goes":
        if was_asked and not picking:
            return "askedWhenDecided"
    return None


class Budget:
    def __init__(self, max_calls: int):
        self.max, self.used = max_calls, 0

    def take(self):
        if self.used >= self.max:
            raise StopRun(f"--max-calls {self.max} reached")
        self.used += 1


class StopRun(Exception):
    pass


def post(url: str, key: str, body: dict, timeout: float = 90) -> tuple[int, dict]:
    req = urllib.request.Request(url, data=json.dumps(body, ensure_ascii=False).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "x-goog-api-key": key})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}
    except (TimeoutError, urllib.error.URLError, OSError) as e:
        return 503, {"error": {"status": "TIMEOUT", "message": type(e).__name__}}


def run_case(case: dict, setup: dict, model: str, key: str, budget: Budget, read_only: set, send=post) -> list[dict]:
    """One run of a case: per driver turn, the tools she called, whether she asked, and the failure (or None)."""
    url = f"{HOST}/v1beta/models/{model}:generateContent"
    decls = [{"name": t["name"], "description": t["description"], "parametersJsonSchema": t["parameters"]}
             for t in setup["tools"]]
    contents = [{"role": "user", "parts": [{"text": "\n".join(setup["notes"])}]}]
    contents.append({"role": "model", "parts": [{"text": "好的。"}]})
    for h in case["history"]:
        contents.append({"role": h["role"], "parts": [{"text": h["text"]}]})
    out = []
    for turn in case["turns"]:
        contents.append({"role": "user", "parts": [{"text": turn["said"]}]})
        tools, text, picking = [], "", False
        for _ in range(MAX_TOOL_ROUNDS + 1):
            body = {"systemInstruction": {"parts": [{"text": setup["instruction"]}]},
                    "contents": contents, "tools": [{"functionDeclarations": decls}]}
            for attempt in range(RETRIES):
                budget.take()
                status, reply = send(url, key, body)
                raw = json.dumps(reply, ensure_ascii=False)
                # Bounded retries (dev.to "Bounded retries for agent tool calls", F-18 §32): only a 503 overload or
                # a 429 that is not a quota error; every try counts against --max-calls.
                if status in (429, 503) and not any(q in raw for q in QUOTA) and attempt + 1 < RETRIES:
                    sleep(WAIT[attempt])
                    continue
                break
            if status != 200:
                if any(q in raw for q in QUOTA):
                    raise StopRun("quota error")
                raise StopRun(f"HTTP {status}: {raw[:200]}")
            parts = ((reply.get("candidates") or [{}])[0].get("content") or {}).get("parts") or []
            contents.append({"role": "model", "parts": parts or [{"text": ""}]})
            calls = [p["functionCall"] for p in parts if "functionCall" in p]
            text += "".join(p.get("text", "") for p in parts if not p.get("thought"))
            if not calls:
                break
            responses = []
            for c in calls:
                tools.append(c["name"])
                picking = picking or c["name"] in PICKING
                responses.append({"functionResponse": {"name": c["name"], "response": FAKE.get(c["name"], {"ok": True})}})
            contents.append({"role": "user", "parts": responses})
        was_asked = asked(text)
        out.append({"said": turn["said"], "tools": tools, "asked": was_asked, "reply": text.strip(),
                    "failure": score(turn["expect"], tools, was_asked, picking, read_only)})
        if out[-1]["failure"]:
            break
    return out


def planned(cases: list, runs: dict) -> int:
    """Upper bound: every turn may take 1 + MAX_TOOL_ROUNDS calls; the usual cost is ~1.5 per turn."""
    return sum(runs[c["group"]] * len(c["turns"]) * 2 for c in cases)


def main(argv=None, env=os.environ, send=post, ask=input) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("export", help="JSON from EvalExportTests")
    p.add_argument("--setting", default="search", choices=["search", "nosearch"])
    p.add_argument("--model", default="gemini-3.8-flash")
    p.add_argument("--runs", type=int, default=10, help="runs per AskOrActEval case")
    p.add_argument("--complaint-runs", type=int, default=5)
    p.add_argument("--max-calls", type=int, default=None, help="stop after N paid calls (default: the planned count)")
    p.add_argument("--yes", action="store_true")
    p.add_argument("--out", required=True, help="results JSON")
    a = p.parse_args(argv)
    key = env.get("GEMINI_API_KEY", "")
    if not key:
        print("GEMINI_API_KEY is not set", file=sys.stderr)
        return 2
    data = json.loads(pathlib.Path(a.export).read_text(encoding="utf-8"))
    setup, cases, read_only = data[a.setting], data["cases"], set(data["readOnly"])
    runs = {"askOrAct": a.runs, "complaint": a.complaint_runs}
    plan = planned(cases, runs)
    max_calls = plan if a.max_calls is None else a.max_calls
    print(f"planned paid calls: about {plan // 2}, at most {plan}; max-calls {max_calls}; model: {a.model}", flush=True)
    if not a.yes and ask("send? [y/N] ").strip().lower() != "y":
        print("not started: 0 calls")
        return 1
    budget, results, stopped = Budget(max_calls), [], None
    try:
        for c in cases:
            for n in range(runs[c["group"]]):
                turns = run_case(c, setup, a.model, key, budget, read_only, send=send)
                results.append({"case": c["id"], "group": c["group"], "run": n + 1, "turns": turns,
                                "failure": next((t["failure"] for t in turns if t["failure"]), None)})
                print(f"{c['id']} run {n + 1}: {results[-1]['failure'] or 'pass'}", flush=True)
                time.sleep(0.2)
    except StopRun as e:
        stopped = str(e)
        print(f"stopped: {e}", flush=True)
    report = {}
    for r in results:
        k = report.setdefault(r["case"], {"group": r["group"], "runs": 0, "passed": 0, "failures": {}})
        k["runs"] += 1
        if r["failure"]:
            k["failures"][r["failure"]] = k["failures"].get(r["failure"], 0) + 1
        else:
            k["passed"] += 1
    for k in report.values():
        k["pass"] = k["runs"] > 0 and k["passed"] * 10 >= k["runs"] * 9
    pathlib.Path(a.out).write_text(json.dumps({"model": a.model, "setting": a.setting, "calls": budget.used,
                                               "stopped": stopped, "report": report, "runs": results},
                                              ensure_ascii=False, indent=1), encoding="utf-8")
    for cid, k in report.items():
        print(f"ask-or-act case={cid} runs={k['runs']} passed={k['passed']} pass={'yes' if k['pass'] else 'no'} "
              + " ".join(f"{f}={n}" for f, n in sorted(k["failures"].items())))
    print(f"calls used: {budget.used}")
    return 0 if not stopped else 1


if __name__ == "__main__":
    sys.exit(main())
