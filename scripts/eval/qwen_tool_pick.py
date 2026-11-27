#!/usr/bin/env python3
"""Does the Qwen-Audio realtime model pick the right tool? Fake tools, real model.

Opens a Qwen realtime session with the app's own instruction text and tool declarations (from
specs/contracts/agent-setup-parts/<version>.json, the setup the phone records as agentHash), sends each scenario's
context notes and driver sentence as text, answers every tool call with a fake result, and records which tool the
model called (or that it only talked). Every event sent and received is saved to D:/ndlogs/search-raw/.

Usage (each session ~16k tokens; --max-calls caps sessions, a quota error stops the run):
  python scripts/eval/qwen_tool_pick.py --setup <setup json> [--model qwen-audio-3.1-realtime-flash]
      [--only S1,S2] [--runs 1] [--audio] [--show | --mix] [--max-calls 20] [--gap 20]
Key: DASHSCOPE_API_KEY_CN (Beijing). Uses the model's free quota; run --only S1 first to see the cost of one session.
"""
import argparse, asyncio, datetime, json, os, pathlib, sys, time

import websockets

ENDPOINT = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model={model}"
RAW = pathlib.Path("D:/ndlogs/search-raw")

SCREEN_OFF = ("[系统] 屏幕：destinationList off，routePicking off，routeCalculating off，navigation off，tripNextButton off，"
              "stopNavigationButton off，tripScreen off，tripDetail off，tripPlans off，musicCard off，music off，musicVolume 2，"
              "mapPin off，camera off，working off，backgroundWork off，settings off，top none。这句不用回答")
NOW = "[系统] 现在：位置：广东省珠海市香洲区（在高速上：否），本地时间 2026-11-27 周五 09:17。这句不用回答"
SUMMARY_B = ("[系统] 上次对话的最后几句：司机「帮我规划一下这周周末的行程吧，我想看一下珠海跟澳门的景点，最好包括一些活动」→ 你"
             "「行程规划好啦！第一天周六去横琴VAC电音节，住长隆企鹅酒店；第二天周日去大三巴牌坊、澳门旅游塔和威尼斯人。」（plan_trip）。这句不用回答")
TRIP_STATE = ("[系统] 已保存行程：珠海+澳门 2 天，2026-11-28 起。第1天：横琴VAC电音节（长隆度假区），住长隆企鹅酒店；"
              "第2天：大三巴牌坊、澳门旅游塔、澳门威尼斯人。行程屏幕：已关闭。这句不用回答")

# id, notes before the sentence, driver sentence, acceptable tools (empty = should only talk)
SCENARIOS = [
    ("S1", [NOW, SCREEN_OFF], "帮我规划一下这周末的行程吧，我想看珠海跟澳门的景点，最好包括一些活动", {"plan_trip"}),
    ("S2", [NOW, SCREEN_OFF, SUMMARY_B], "你帮我看一下吧，就是这两边的景点还有活动", {"plan_trip", "trip_plans"}),
    ("S3", [NOW, SCREEN_OFF, SUMMARY_B], "行程呢", {"plan_trip", "trip_plans"}),
    ("S4", [NOW, SCREEN_OFF, TRIP_STATE], "给我看一下行程", {"trip_plans"}),
    ("S5", [NOW, SCREEN_OFF, TRIP_STATE], "改成只玩一天，就去澳门", {"plan_trip"}),
    ("S6", [NOW, SCREEN_OFF, TRIP_STATE], "开始第一天", {"trip_next"}),
    ("S7", [NOW, SCREEN_OFF], "最近珠海跟澳门有什么活动", {"find_events"}),
    ("S8", [NOW, SCREEN_OFF], "有点热", {"control_climate"}),
    ("S9", [NOW, SCREEN_OFF], "导航去珠海站", {"navigate_to"}),
    ("S10", [NOW, SCREEN_OFF], "你好呀", set()),
]

FAKE = {
    "plan_trip": {"next": "已经交给后台去做，系统会告诉司机。现在不用说话，结果稍后发给你。结果还没回来，不要说已经做好", "status": "running"},
    "find_events": {"next": "已经交给后台去做，系统会告诉司机。现在不用说话，结果稍后发给你。结果还没回来，不要说已经做好", "status": "running"},
}


def instructions_and_tools(setup: dict, style: str, search: bool):
    parts = setup["parts"]
    mode = "search" if search else "nosearch"
    instructions = parts[f"base.{style}.{mode}"]
    tools = []
    prefix = f"tool.{mode}."
    names = sorted({k[len(prefix):].rsplit(".", 1)[0] for k in parts if k.startswith(prefix)})
    for name in names:
        tools.append({"type": "function", "function": {
            "name": name,
            "description": parts[f"{prefix}{name}.description"],
            "parameters": json.loads(parts[f"{prefix}{name}.schema"]),
        }})
    return instructions, tools


# Proposed (not in the app): trip_plans gains action "show" that opens the current trip screen, no name needed.
SHOW_LINE = "司机要看现在这份行程（「行程呢」「给我看一下行程」「把行程打开」）→show，不填 name；"


def add_show_action(tools):
    for t in tools:
        f = t["function"]
        if f["name"] == "trip_plans":
            f["description"] = SHOW_LINE + f["description"]
            f["parameters"]["properties"]["action"]["enum"] = ["show"] + f["parameters"]["properties"]["action"]["enum"]
    return tools


# Show-trip cases: (id, notes, sentence). PASS = trip_plans with action "show" as the first call.
SHOW_SCENARIOS = [
    ("V1", [NOW, SCREEN_OFF, TRIP_STATE], "给我看一下行程"),
    ("V2", [NOW, SCREEN_OFF, TRIP_STATE], "行程呢"),
    ("V3", [NOW, SCREEN_OFF, SUMMARY_B], "给我看一下行程"),
    ("V4", [NOW, SCREEN_OFF, SUMMARY_B], "行程呢"),
    ("V5", [NOW, SCREEN_OFF, TRIP_STATE], "不是你给我看一下吧"),
]


# Mixed plan vs show cases (with the proposed "show" action): (id, notes, sentence, expected "plan" | "show").
MIX_SCENARIOS = [
    ("M1", [NOW, SCREEN_OFF], "帮我规划一下这周末珠海和澳门两天的行程", "plan"),
    ("M2", [NOW, SCREEN_OFF, TRIP_STATE], "行程呢", "show"),
    ("M3", [NOW, SCREEN_OFF, TRIP_STATE], "重新规划一个吧，改去广州玩一天", "plan"),
    ("M4", [NOW, SCREEN_OFF, TRIP_STATE], "改成只玩一天，就去澳门", "plan"),
    ("M5", [NOW, SCREEN_OFF, SUMMARY_B], "帮我规划一下这周末珠海跟澳门的行程，景点和活动都要", "plan"),
    ("M6", [NOW, SCREEN_OFF, SUMMARY_B], "把刚才那个行程打开给我看看", "show"),
]


def mix_verdict(first_calls, expected):
    if not first_calls:
        return "TALK_ONLY"
    c = first_calls[0]
    args = json.loads(c["arguments"] or "{}")
    got = ("show" if c["name"] == "trip_plans" and args.get("action") == "show"
           else "plan" if c["name"] == "plan_trip" else c["name"] + ":" + str(args.get("action", "")))
    return "PASS" if got == expected else f"GOT_{got}"


async def run_one(key, model, instructions, tools, scenario, audio, log):
    sid, notes, sentence, expected = scenario
    url = ENDPOINT.format(model=model)
    calls, texts, usage = [], [], []

    async with websockets.connect(url, additional_headers={"Authorization": f"Bearer {key}"}, max_size=None,
                                  open_timeout=20) as ws:
        async def send(obj):
            log.write(json.dumps({"dir": "out", "t": time.time(), "event": obj}, ensure_ascii=False) + "\n")
            await ws.send(json.dumps(obj, ensure_ascii=False))

        async def until_done(timeout=40):
            """Read events until response.done; return the function calls of that response."""
            got = []
            text = []
            deadline = time.time() + timeout
            while time.time() < deadline:
                raw = await asyncio.wait_for(ws.recv(), timeout=max(1, deadline - time.time()))
                ev = json.loads(raw)
                slim = {k: v for k, v in ev.items() if k != "delta" or ev.get("type", "").endswith(("text.delta", "transcript.delta"))}
                log.write(json.dumps({"dir": "in", "t": time.time(), "event": slim}, ensure_ascii=False) + "\n")
                t = ev.get("type", "")
                if t in ("response.text.delta", "response.audio_transcript.delta"):
                    text.append(ev.get("delta", ""))
                elif t == "response.function_call_arguments.done":
                    got.append({"name": ev.get("name"), "arguments": ev.get("arguments"), "call_id": ev.get("call_id")})
                elif t == "response.done":
                    usage.append((ev.get("response") or {}).get("usage"))
                    return got, "".join(text)
                elif t == "error":
                    raise RuntimeError(json.dumps(ev, ensure_ascii=False))
            raise TimeoutError("no response.done")

        session = {
            "modalities": ["text", "audio"] if audio else ["text"],
            "instructions": instructions,
            "voice": "longanqian_v3.1",
            "turn_detection": None,
            "tools": tools,
        }
        await send({"type": "session.update", "session": session})
        for note in notes:
            await send({"type": "conversation.item.create", "item": {"type": "message", "role": "user",
                                                                     "content": [{"type": "input_text", "text": note}]}})
        await send({"type": "conversation.item.create", "item": {"type": "message", "role": "user",
                                                                 "content": [{"type": "input_text", "text": sentence}]}})
        await send({"type": "response.create"})
        first_calls, first_text = await until_done()
        calls += first_calls
        texts.append(first_text)
        # One follow-up: answer every call with a fake result, see what she says next.
        if first_calls:
            for c in first_calls:
                result = FAKE.get(c["name"], {"ok": True, "next": "按结果说一句"})
                await send({"type": "conversation.item.create", "item": {
                    "type": "function_call_output", "call_id": c["call_id"],
                    "output": json.dumps(result, ensure_ascii=False)}})
            await send({"type": "response.create"})
            more_calls, more_text = await until_done()
            calls += more_calls
            texts.append(more_text)

    picked = [c["name"] for c in calls]
    first = first_calls[0]["name"] if first_calls else None
    if isinstance(expected, str) and expected.startswith("mix:"):
        verdict = mix_verdict(first_calls, expected[4:])
    elif expected == "show":
        args = json.loads(first_calls[0]["arguments"] or "{}") if first_calls else {}
        verdict = ("PASS" if first == "trip_plans" and args.get("action") == "show"
                   else "TALK_ONLY" if first is None else "WRONG_TOOL")
    elif expected:
        verdict = "PASS" if first in expected else ("TALK_ONLY" if first is None else "WRONG_TOOL")
    else:
        verdict = "PASS" if first is None else "UNNEEDED_TOOL"
    return {"id": sid, "sentence": sentence, "expected": expected if isinstance(expected, str) else sorted(expected), "first_tool": first, "all_tools": picked,
            "args": [c["arguments"] for c in calls], "reply": texts, "usage": usage, "verdict": verdict}


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--setup", required=True)
    ap.add_argument("--model", default="qwen-audio-3.1-realtime-flash")
    ap.add_argument("--style", default="gentle")
    ap.add_argument("--only", default="")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--audio", action="store_true", help="ask for audio too (as the app does; costs more)")
    ap.add_argument("--show", action="store_true", help="add the proposed trip_plans action \"show\" and run the "
                    "show-trip cases V1-V5")
    ap.add_argument("--max-calls", type=int, default=20, help="most sessions this run may open (F-18 §32 item 6); "
                    "one session is about 16k tokens of the model's free quota")
    ap.add_argument("--mix", action="store_true", help="with the proposed \"show\" action: cases M1-M6 where either "
                    "plan_trip or show is right")
    ap.add_argument("--gap", type=float, default=20, help="seconds between sessions (Flash returned "
                    "'Allocated quota exceeded' after 6 back-to-back sessions on 2026-11-27; it cleared within 75 s)")
    a = ap.parse_args()
    key = os.environ.get("DASHSCOPE_API_KEY_CN")
    if not key:
        sys.exit("DASHSCOPE_API_KEY_CN is not set")
    setup = json.load(open(a.setup, encoding="utf-8"))
    instructions, tools = instructions_and_tools(setup, a.style, True)
    pool = SCENARIOS
    if a.show:
        tools = add_show_action(tools)
        pool = [(i, n, s, "show") for i, n, s in SHOW_SCENARIOS]
    if a.mix:
        tools = add_show_action(tools)
        pool = [(i, n, s, "mix:" + e) for i, n, s, e in MIX_SCENARIOS]
    chosen = [s for s in pool if not a.only or s[0] in a.only.split(",")]
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    RAW.mkdir(parents=True, exist_ok=True)
    raw_path = RAW / f"{stamp}-qwen_tool_pick-{a.model}.jsonl"
    out_path = RAW / f"{stamp}-qwen_tool_pick-{a.model}-results.json"
    results = []
    with open(raw_path, "w", encoding="utf-8") as log:
        log.write(json.dumps({"setup": setup.get("version"), "model": a.model, "tools": len(tools),
                              "audio": a.audio}, ensure_ascii=False) + "\n")
        for r in range(a.runs):
            for s in chosen:
                if len(results) >= a.max_calls:
                    print(f"stopped at --max-calls {a.max_calls}")
                    break
                if results:
                    await asyncio.sleep(a.gap)
                log.write(json.dumps({"scenario": s[0], "run": r + 1}, ensure_ascii=False) + "\n")
                try:
                    res = await run_one(key, a.model, instructions, tools, s, a.audio, log)
                except Exception as e:  # keep going; the error is in the raw log too
                    res = {"id": s[0], "sentence": s[2], "verdict": "ERROR", "error": str(e)}
                res["run"] = r + 1
                results.append(res)
                if "quota" in res.get("error", "").lower():
                    print("stopped: quota error (F-18 §32 item 6)")
                    break
                tok = sum((u or {}).get("total_tokens", 0) for u in res.get("usage", []))
                print(f"{res['id']:>4} run{r + 1} {res['verdict']:<13} first={res.get('first_tool')} "
                      f"all={res.get('all_tools')} tokens={tok} | {s[2]}")
                for t in res.get("reply", []):
                    if t:
                        print(f"       she: {t[:120]}")
    json.dump(results, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"raw: {raw_path}\nresults: {out_path}")


if __name__ == "__main__":
    asyncio.run(main())
