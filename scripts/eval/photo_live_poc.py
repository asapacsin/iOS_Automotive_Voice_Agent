"""Live PoC: gemini-3.8-live with the app's 10.1.0 setup; the driver's recorded words sent as text.
Does she call show_places/show_place when asked for pictures? F-09b §21 row 2.
Usage: python photo_live_poc.py <repo> <record> [runs] [--with-next] [--max-calls N]
Paid calls (F-18 §32 item 6): one Live session per run; stops at --max-calls (default 10)."""
import asyncio, json, os, re, sys
import websockets

args = sys.argv[1:]
MAX_CALLS = int(args[args.index("--max-calls") + 1]) if "--max-calls" in args else 10
WITH_NEXT = "--with-next" in args
pos = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--max-calls")]
repo, record = pos[0], pos[1]
RUNS = int(pos[2]) if len(pos) > 2 else 5
NEXT = "answer 里有地点时，用 show_places 把它们列在屏幕上（每个是带照片的卡片），再简短说找到了哪些。"
calls = 0
KEY = os.environ["GEMINI_API_KEY"].strip()
URL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
ASYNC = {"web_search", "query_live_info", "show_place", "plan_trip"}

parts = json.load(open(f"{repo}/specs/contracts/agent-setup-parts/10.1.0.json", encoding="utf-8"))["parts"]
names = sorted({k.split(".")[2] for k in parts if k.startswith("tool.search.")})
decls = []
for n in names:
    d = {"name": n, "description": parts[f"tool.search.{n}.description"],
         "parametersJsonSchema": json.loads(parts[f"tool.search.{n}.schema"])}
    if n in ASYNC: d["behavior"] = "NON_BLOCKING"
    decls.append(d)
SETUP = {"setup": {"model": "models/" + parts.get("model", "gemini-3.8-live"),
                   "generationConfig": {"responseModalities": ["AUDIO"]},
                   "systemInstruction": {"parts": [{"text": parts["base.gentle.search"]}]},
                   "tools": [{"functionDeclarations": decls}], "outputAudioTranscription": {}}}

lines = open(record, encoding="utf-8").read().splitlines()
def result(ts):
    l = next(x for x in lines if x.startswith(f"{ts} tool-result"))
    return json.loads(l[l.index("{"):])
SEARCH = result("75996")
# F-09b §21 item 1 (T-031zf review): the app appends to the recorded next; it never replaces it.
if WITH_NEXT: SEARCH["next"] = SEARCH.get("next", "") + NEXT

def t(role, text): return {"role": role, "parts": [{"text": text}]}
BASE = [t("user", "Hello,小诺。"), t("model", "您好！我是小诺，随时准备为您提供帮助，请问有什么需要吗？"),
        t("user", "是这样子的, 最近我太久没去旅行。"), t("model", "听起来您最近很忙呢，是想计划一次放松的旅行吗？"),
        t("user", "是这样子的, 我想去一些异国风情的度假村, 在这附近的。有吗?"),
        t("model", "珠海度假村酒店有日式和风古式客房，风格独特，您可以考虑看看是否喜欢。")]
CASES = {"A ask for pictures": (BASE, "我想去海边度假村, 有有图片或者啥的可以看一下吗?"),
         "B after her refusal": (BASE + [t("user", "我想去海边度假村, 有有图片或者啥的可以看一下吗?"),
             t("model", "珠海凤凰湾悦榕庄和海泉灣度假區评价都很高，由于我无法直接显示图片，建议您在旅游平台上看看实景图。")],
             "那个检索图片的功能吗? 你给我看一下图片吧。")}
REFUSE = re.compile(r"(无法|不能|没有|不支持).{0,10}(显示|展示|检索|看|发).{0,4}(图片|照片)")

def fake(name, args):
    if name == "web_search": return dict(SEARCH)
    if name in ("show_places", "show_place"):
        ps = args.get("places") or [{"name": args.get("name", "")}]
        return {"ok": True, "shown": True, "places": [{"name": p.get("name"), "located": True} for p in ps]}
    return {"ok": True}

async def run(hist, said):
    global calls
    if calls >= MAX_CALLS: raise SystemExit(f"stopped at --max-calls {MAX_CALLS}")
    calls += 1
    tools, text = [], ""
    async with websockets.connect(URL, additional_headers={"x-goog-api-key": KEY}, max_size=None) as ws:
        await ws.send(json.dumps(SETUP)); await ws.recv()
        await ws.send(json.dumps({"clientContent": {"turns": hist + [t("user", said)], "turnComplete": True}}))
        done = 0
        while True:
            try: msg = json.loads(await asyncio.wait_for(ws.recv(), 25))
            except (asyncio.TimeoutError, websockets.ConnectionClosed): break
            sc = msg.get("serverContent") or {}
            text += (sc.get("outputTranscription") or {}).get("text", "")
            if "toolCall" in msg:
                resps = []
                for c in msg["toolCall"].get("functionCalls", []):
                    tools.append(c["name"] + json.dumps(c.get("args", {}), ensure_ascii=False)[:120])
                    r = fake(c["name"], c.get("args", {}))
                    if c["name"] in ASYNC: r["scheduling"] = "WHEN_IDLE"
                    resps.append({"id": c["id"], "name": c["name"], "response": r})
                await ws.send(json.dumps({"toolResponse": {"functionResponses": resps}}))
            if sc.get("turnComplete"):
                done += 1
                if done >= 3 or (done >= 1 and any(x.startswith("show_place") for x in tools)):
                    try: msg = await asyncio.wait_for(ws.recv(), 6)
                    except Exception: pass
                    break
    return tools, text

async def main():
    summary = {}
    for label, (hist, said) in CASES.items():
        ok = 0
        for i in range(RUNS):
            tools, text = await run(hist, said)
            picked = any(x.startswith("show_place") for x in tools)
            refused = bool(REFUSE.search(text))
            ok += picked and not refused
            print(f"[{label}] run {i+1}: picked={picked} refused={refused}\n  tools={tools}\n  said={text.strip()[:220]}", flush=True)
        summary[label] = f"{ok}/{RUNS}"
    print("SUMMARY", json.dumps(summary, ensure_ascii=False))
asyncio.run(main())
