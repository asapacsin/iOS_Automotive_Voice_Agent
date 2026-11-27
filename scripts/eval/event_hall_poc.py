#!/usr/bin/env python3
"""PoC (owner 2026-11-27): does the voice model pass the event's hall and the trip's date to plan_trip?

Replays record 20261127-151819 (build ee5c143) live, turn by turn, on the phone's realtime model with the app's setup
(13.0.0), in two arms:
  old: today's tools; find_events answers as the app does (one entry per event, both halls in 「场馆：」).
  new: find_events gives each event (and each hall of a multi-hall event) an id; plan_trip.asked gains `events` (ids)
       and `when` (the driver's date words). A plan_trip that names a multi-hall event without a hall id is rejected
       once by code, naming the field (as the app would), and she gets one more response.
Cases: F = the failure (AIE, driver said 威尼斯, 下个星期周末); C1 = single-hall event that worked before (VAC);
C2 = no event (device row 360). Every event is saved to D:/ndlogs/search-raw/.

Usage: python scripts/eval/event_hall_poc.py --plan F:old:1,F:new:3,C1:old:1,C1:new:1,C2:old:1,C2:new:1 [--model ...]
Key: DASHSCOPE_API_KEY_CN.
"""
import argparse, asyncio, copy, datetime, json, os, pathlib, sys, time

import websockets

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from qwen_tool_pick import ENDPOINT, RAW, SCREEN_OFF, instructions_and_tools  # noqa: E402

NOW = "[系统] 现在：位置：广东省珠海市香洲区（在高速上：否），本地时间 2026-11-27 周五 15:18。这句不用回答"
SEARCH_NEXT = "这是3分钟前查到的，这些是网上查到的活动，日期以主办方为准。按日期跟司机说名字、日期、地点，一两句，提醒出发前核实；没有就说这几类在网上没查到，不要说一定没有。"
RUNNING = {"next": "已经交给后台去做，系统会告诉司机。现在不用说话，结果稍后发给你。结果还没回来，不要说已经做好", "status": "running"}

# The store's entries as in the record (turn 3 read them out).
EVENTS = [
    ("2026橫琴VAC電音節（秋季）", "珠海", ["广东珠海横琴长隆度假区"], "2026-11-28", "2026-11-29"),
    ("LINGORM澳门粉丝见面会", "澳门", ["澳门伦敦人综艺馆"], "2026-11-28", "2026-11-28"),
    ("全球智能制造与电子产品博览会", "珠海", ["珠海国际会展中心", "澳门威尼斯人金光会展中心"], "2026-12-03", "2026-12-05"),
    ("爱奇艺尖叫嘉年华", "澳门", ["澳门银河国际会议中心前地"], "2026-12-04", "2026-12-05"),
]


def old_result():
    ev = [{"name": n, "city": c, "facts": f"场馆：{'、'.join(h)}；日期：{s}–{e}", "source_url": "https://example.invalid",
           "image": "未找到这个活动的图片"} for n, c, h, s, e in EVENTS]
    return {"events": ev, "dropped": 0, "sites": [], "source": "store", "next": SEARCH_NEXT, "searched_minutes_ago": 3}


def new_ids():
    """e1, e2, e3a, e3b, e4: one id per hall."""
    out = []
    for i, (n, c, halls, s, e) in enumerate(EVENTS, 1):
        for j, h in enumerate(halls):
            out.append((f"e{i}" + ("abcdef"[j] if len(halls) > 1 else ""), n, c, h, s, e, len(halls) > 1))
    return out


def new_result():
    ev = [{"id": i, "name": n, "city": c, "facts": f"场馆：{h}；日期：{s}–{e}", "source_url": "https://example.invalid",
           "image": "未找到这个活动的图片"} for i, n, c, h, s, e, _ in new_ids()]
    nxt = SEARCH_NEXT + "同一个活动有几个场馆时分开列出，每个场馆一个 id。"
    return {"events": ev, "dropped": 0, "sites": [], "source": "store", "next": nxt, "searched_minutes_ago": 3}


NEW_LINE = ("司机说喜欢或问某个活动时只回答，不调用；司机要你做行程时，行程里有 find_events 查到的活动，asked.events 填那个活动的 id；同一个活动有几个场馆时，填司机说的那个场馆的 id，"
            "司机没说哪个场馆就先问他。asked.when 照司机说日期的原话写（比如「下个星期周末」「这周六」），没说就不写。")


def new_tools(tools):
    tools = copy.deepcopy(tools)
    for t in tools:
        f = t["function"]
        if f["name"] == "plan_trip":
            f["description"] = f["description"].replace("调用后不用说话", NEW_LINE + "调用后不用说话")
            props = f["parameters"]["properties"]["asked"]["properties"]
            props["events"] = {"type": "array", "maxItems": 5, "items": {"type": "string", "minLength": 1, "maxLength": 8}}
            props["when"] = {"type": "string", "minLength": 1, "maxLength": 30}
    return tools


def code_check(args):
    """The new arm's rejection: a multi-hall event named in must/text without one of its hall ids."""
    asked = args.get("asked") or {}
    ids = set(asked.get("events") or [])
    words = " ".join([asked.get("text", "")] + list(asked.get("must") or []) + list(asked.get("notes") or []))
    for n, _, halls, _, _ in EVENTS:
        if len(halls) < 2:
            continue
        mine = [i for i, nn, _, _, _, _, multi in new_ids() if nn == n]
        if (n in words or "博览会" in words) and not ids & set(mine):
            opts = "，".join(f"{i} {h}" for i, nn, _, h, _, _, _ in new_ids() if nn == n)
            return {"ok": False, "code": "INVALID_ARGUMENT", "field": "asked.events",
                    "next": f"asked.events 没填：{n}有两个场馆（{opts}），填司机说的那个场馆的 id；司机没说就问他去哪个。"}
    return None


CASES = {
    "F": [("user", "帮我找一下最近澳门、珠海有什么活动？"),
          ("user", "人工智能，那个在威尼斯的那，那个挺好的。"),
          ("user", "帮我安排一下吧，呃就下个星期周末帮我安排一下两天这个澳门跟珠海的一个旅行吧，然后包括那个活动。"),
          ("user", "包括一下周边的景点吧，就是澳门、珠海两天游。")],
    "C1": [("user", "帮我找一下最近珠海有什么活动？"),
           ("user", "那个电音节挺好的。"),
           ("user", "这周末帮我安排珠海两天，包括那个电音节。")],
    "C2": [("user", "这周末珠海两天，景点和活动，第一天加长隆海洋王国，第二天去日月贝")],
}


def verdict(case, arm, call):
    if call is None:
        return "NO_PLAN_TRIP"
    a = json.loads(call or "{}").get("asked") or {}
    events, when, start = a.get("events") or [], a.get("when", ""), a.get("start", "")
    if case == "F":
        date_ok = "下" in when and "周末" in when or start == "2026-12-05"
        hall_ok = (events == ["e3b"]) if arm == "new" else ("威尼斯" in json.dumps(a, ensure_ascii=False))
        return ("PASS" if date_ok and hall_ok else "FAIL") + f" hall={'ok' if hall_ok else 'missing'} date={'ok' if date_ok else 'missing'}"
    if case == "C1":
        date_ok = "这周末" in when or start == "2026-11-28"
        ev_ok = (events == ["e1"]) if arm == "new" else any("电音" in m for m in a.get("must") or [a.get("text", "")])
        return ("PASS" if date_ok and ev_ok else "FAIL") + f" event={'ok' if ev_ok else 'missing'} date={'ok' if date_ok else 'missing'}"
    date_ok = "这周末" in when or start == "2026-11-28"
    must = " ".join(a.get("must") or [])
    ok = date_ok and "长隆" in must and "日月贝" in must and not events
    return ("PASS" if ok else "FAIL") + f" date={'ok' if date_ok else 'missing'} must={must}"


async def run(key, model, instructions, tools, case, arm, log, usage):
    url = ENDPOINT.format(model=model)
    async with websockets.connect(url, additional_headers={"Authorization": f"Bearer {key}"}, max_size=None,
                                  open_timeout=20) as ws:
        async def send(o):
            log.write(json.dumps({"dir": "out", "t": time.time(), "event": o}, ensure_ascii=False) + "\n")
            await ws.send(json.dumps(o, ensure_ascii=False))

        async def respond(timeout=60):
            await send({"type": "response.create"})
            got, text, deadline = [], [], time.time() + timeout
            while time.time() < deadline:
                ev = json.loads(await asyncio.wait_for(ws.recv(), timeout=max(1, deadline - time.time())))
                slim = {k: v for k, v in ev.items() if k != "delta" or ev.get("type", "").endswith(("text.delta", "transcript.delta"))}
                log.write(json.dumps({"dir": "in", "t": time.time(), "event": slim}, ensure_ascii=False) + "\n")
                t = ev.get("type", "")
                if t in ("response.text.delta", "response.audio_transcript.delta"):
                    text.append(ev.get("delta", ""))
                elif t == "response.function_call_arguments.done":
                    got.append({"name": ev.get("name"), "arguments": ev.get("arguments"), "call_id": ev.get("call_id")})
                elif t == "response.done":
                    usage.append(((ev.get("response") or {}).get("usage") or {}).get("total_tokens", 0))
                    return got, "".join(text)
                elif t == "error":
                    raise RuntimeError(json.dumps(ev, ensure_ascii=False))
            raise TimeoutError("no response.done")

        def item(text):
            return {"type": "conversation.item.create", "item": {"type": "message", "role": "user",
                                                                 "content": [{"type": "input_text", "text": text}]}}

        await send({"type": "session.update", "session": {"modalities": ["text"], "instructions": instructions,
                                                          "voice": "longanqian_v3.1", "turn_detection": None, "tools": tools}})
        for n in (NOW, SCREEN_OFF):
            await send(item(n))
        transcript, plan_args, rejected = [], None, False
        for _, said in CASES[case]:
            await send(item(said))
            transcript.append(f"司机: {said}")
            for _ in range(4):  # answer tool calls until she only talks
                calls, text = await respond()
                if text:
                    transcript.append(f"她: {text}")
                if not calls:
                    break
                for c in calls:
                    transcript.append(f"调用 {c['name']} {c['arguments']}")
                    if c["name"] == "find_events":
                        out = new_result() if arm == "new" else old_result()
                    elif c["name"] == "plan_trip":
                        bad = code_check(json.loads(c["arguments"] or "{}")) if arm == "new" and not rejected else None
                        if bad:
                            rejected = True
                            out = bad
                            transcript.append(f"代码拒绝 {bad['next']}")
                        else:
                            plan_args = plan_args or c["arguments"]
                            out = RUNNING
                    else:
                        out = {"ok": True, "next": "按结果说一句"}
                    await send({"type": "conversation.item.create", "item": {"type": "function_call_output",
                                "call_id": c["call_id"], "output": json.dumps(out, ensure_ascii=False)}})
            if plan_args:
                break
        return plan_args, transcript, rejected


GEMINI_CHAT = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
GEMINI = [False]
CHAT = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"


async def run_text(key, model, instructions, tools, case, arm, log, usage):
    """Same replay on a text model (compatible chat, tools as functions): the realtime free quota is used up."""
    import urllib.request

    def chat(messages):
        body = {"model": model, "messages": messages, "tools": tools}
        if not GEMINI[0]:
            body["enable_thinking"] = False
        log.write(json.dumps({"dir": "out", "t": time.time(), "body": body}, ensure_ascii=False) + "\n")
        for wait in (10, 30, 60, 60, None):  # 503 high demand / 429 per-minute: wait and resend (no answer was given)
            req = urllib.request.Request(GEMINI_CHAT if GEMINI[0] else CHAT, data=json.dumps(body, ensure_ascii=False).encode(),
                                         method="POST", headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
            try:
                r = json.load(urllib.request.urlopen(req, timeout=120))
                break
            except urllib.error.HTTPError as e:
                err = e.read().decode("utf-8", "replace")[:300]
                log.write(json.dumps({"dir": "in", "t": time.time(), "http": e.code, "error": err}, ensure_ascii=False) + "\n")
                if e.code not in (429, 503) or wait is None or "PerDay" in err:
                    raise RuntimeError(err)
                time.sleep(wait)
        log.write(json.dumps({"dir": "in", "t": time.time(), "resp": r}, ensure_ascii=False) + "\n")
        usage.append((r.get("usage") or {}).get("total_tokens", 0))
        return r["choices"][0]["message"]

    messages = [{"role": "system", "content": instructions}, {"role": "user", "content": NOW},
                {"role": "user", "content": SCREEN_OFF}]
    transcript, plan_args, rejected = [], None, False
    for _, said in CASES[case]:
        messages.append({"role": "user", "content": said})
        transcript.append(f"司机: {said}")
        for _ in range(4):
            m = chat(messages)
            calls = m.get("tool_calls") or []
            if m.get("content"):
                transcript.append(f"她: {m['content']}")
            messages.append({k: v for k, v in m.items() if k in ("role", "content", "tool_calls")})
            if not calls:
                break
            for c in calls:
                name, argtext = c["function"]["name"], c["function"]["arguments"]
                transcript.append(f"调用 {name} {argtext}")
                if name == "find_events":
                    out = new_result() if arm == "new" else old_result()
                elif name == "plan_trip":
                    bad = code_check(json.loads(argtext or "{}")) if arm == "new" and not rejected else None
                    if bad:
                        rejected, out = True, bad
                        transcript.append(f"代码拒绝 {bad['next']}")
                    else:
                        plan_args, out = plan_args or argtext, RUNNING
                else:
                    out = {"ok": True, "next": "按结果说一句"}
                messages.append({"role": "tool", "tool_call_id": c["id"], "content": json.dumps(out, ensure_ascii=False)})
        if plan_args:
            break
    return plan_args, transcript, rejected


THINKING = [""]
LIVE_URL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"


async def run_live(key, model, instructions, tools, case, arm, log, usage):
    """Same replay on a Gemini Live voice model (audio out, transcript read), one session, turn by turn."""
    decls = [{"name": t["function"]["name"], "description": t["function"]["description"],
              "parametersJsonSchema": t["function"]["parameters"]} for t in tools]
    gen = {"responseModalities": ["AUDIO"]}
    if THINKING[0]:
        gen["thinkingConfig"] = {"thinkingLevel": THINKING[0]}
    setup = {"setup": {"model": "models/" + model, "generationConfig": gen,
                       "systemInstruction": {"parts": [{"text": instructions}]},
                       "tools": [{"functionDeclarations": decls}], "outputAudioTranscription": {}}}
    transcript, plan_args, rejected = [], None, False
    async with websockets.connect(LIVE_URL, additional_headers={"x-goog-api-key": key}, max_size=None,
                                  open_timeout=30) as ws:
        async def send(o):
            log.write(json.dumps({"dir": "out", "t": time.time(), "event": o}, ensure_ascii=False) + "\n")
            await ws.send(json.dumps(o, ensure_ascii=False))

        await send(setup)
        first = json.loads(await asyncio.wait_for(ws.recv(), 30))
        log.write(json.dumps({"dir": "in", "t": time.time(), "event": first}, ensure_ascii=False) + "\n")
        await send({"clientContent": {"turns": [{"role": "user", "parts": [{"text": NOW}]},
                                                {"role": "user", "parts": [{"text": SCREEN_OFF}]}], "turnComplete": False}})
        for _, said in CASES[case]:
            await send({"clientContent": {"turns": [{"role": "user", "parts": [{"text": said}]}], "turnComplete": True}})
            transcript.append(f"司机: {said}")
            text, deadline, wait = "", time.time() + 120, 45
            while time.time() < deadline:
                try:
                    raw = await asyncio.wait_for(ws.recv(), wait)
                except asyncio.TimeoutError:
                    break
                msg = json.loads(raw)
                sc = msg.get("serverContent") or {}
                slim = {k: v for k, v in msg.items() if k != "serverContent"}
                if sc:
                    slim["serverContent"] = {k: v for k, v in sc.items() if k != "modelTurn"}
                log.write(json.dumps({"dir": "in", "t": time.time(), "event": slim}, ensure_ascii=False) + "\n")
                if "usageMetadata" in msg:
                    usage.append(msg["usageMetadata"].get("totalTokenCount", 0))
                text += (sc.get("outputTranscription") or {}).get("text", "")
                if "toolCall" in msg:
                    wait = 45
                    resps = []
                    for c in msg["toolCall"].get("functionCalls", []):
                        name, cargs = c["name"], c.get("args", {})
                        argtext = json.dumps(cargs, ensure_ascii=False)
                        transcript.append(f"调用 {name} {argtext}")
                        if name == "find_events":
                            out = new_result() if arm == "new" else old_result()
                        elif name == "plan_trip":
                            bad = code_check(cargs) if arm == "new" and not rejected else None
                            if bad:
                                rejected, out = True, bad
                                transcript.append(f"代码拒绝 {bad['next']}")
                            else:
                                plan_args, out = plan_args or argtext, RUNNING
                        else:
                            out = {"ok": True, "next": "按结果说一句"}
                        resps.append({"id": c["id"], "name": name, "response": out})
                    await send({"toolResponse": {"functionResponses": resps}})
                if sc.get("turnComplete"):
                    if text:
                        transcript.append(f"她: {text}")
                    text = ""
                    if plan_args:
                        break
                    wait = 8  # after a turn, a tool response may start another; stop after 8 s of quiet
            if plan_args:
                break
    return plan_args, transcript, rejected


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--setup", default="specs/contracts/agent-setup-parts/13.0.0.json")
    ap.add_argument("--model", default="qwen-audio-3.1-realtime-plus")
    ap.add_argument("--plan", default="F:old:1")
    ap.add_argument("--gap", type=float, default=20)
    ap.add_argument("--max-calls", type=int, default=12, help="most sessions this run may open (F-18 §32 item 6)")
    ap.add_argument("--text", action="store_true", help="run on a text model (compatible chat) instead of realtime")
    ap.add_argument("--thinking", default="", help="Live: generationConfig.thinkingConfig.thinkingLevel (extended-thinking needs it)")
    ap.add_argument("--live", action="store_true", help="Gemini Live voice model (bidi), GEMINI_API_KEY")
    ap.add_argument("--gemini", action="store_true", help="with --text: Gemini's OpenAI-compatible endpoint, GEMINI_API_KEY")
    a = ap.parse_args()
    GEMINI[0] = a.gemini or a.live
    THINKING[0] = a.thinking
    var = "GEMINI_API_KEY" if GEMINI[0] else "DASHSCOPE_API_KEY_CN"
    key = (os.environ.get(var) or sys.exit(f"{var} is not set")).strip()
    setup = json.load(open(a.setup, encoding="utf-8"))
    instructions, tools = instructions_and_tools(setup, "gentle", True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    RAW.mkdir(parents=True, exist_ok=True)
    raw, res_path = RAW / f"{stamp}-event_hall_poc.jsonl", RAW / f"{stamp}-event_hall_poc-results.json"
    results, first = [], True
    with open(raw, "w", encoding="utf-8") as log:
        for spec in a.plan.split(","):
            case, arm, n = spec.split(":")
            for r in range(int(n)):
                if len(results) >= a.max_calls:
                    print(f"stopped at --max-calls {a.max_calls}"); break
                if not first:
                    await asyncio.sleep(a.gap)
                first = False
                log.write(json.dumps({"case": case, "arm": arm, "run": r + 1}, ensure_ascii=False) + "\n")
                usage = []
                try:
                    plan, tr, rej = await (run_live if a.live else run_text if a.text else run)(key, a.model, instructions, new_tools(tools) if arm == "new" else tools,
                                              case, arm, log, usage)
                    v = verdict(case, arm, plan)
                except Exception as e:
                    plan, tr, rej, v = None, [], False, f"ERROR {e}"[:300]
                res = {"case": case, "arm": arm, "run": r + 1, "verdict": v, "plan_trip": plan, "rejected_once": rej,
                       "tokens": sum(usage), "transcript": tr}
                results.append(res)
                print(f"{case:>2} {arm} run{r + 1}: {v} rejected={rej} tokens={sum(usage)}\n    plan_trip={plan}")
                json.dump(results, open(res_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
                if "quota" in v.lower():
                    print("stopped: quota"); print(f"raw: {raw}"); return
    print(f"raw: {raw}\nresults: {res_path}")


if __name__ == "__main__":
    asyncio.run(main())
