"""ChatGPT-style browsing PoC: qwen3.8-max loops over search(query) and open_page(url), then answers with events
and their source pages; code checks each event's dates appear in the text of the page it cites.
F-18 §35 PoC (2026-11-24). Usage: python -I -X utf8 event_browse_poc.py [runs] [model] [--max-calls N]
Paid calls (F-18 §32 item 6): every chat and search request counts; stops at --max-calls (default 60)."""
import html, json, os, re, sys, time, urllib.request

ARGS = sys.argv[1:]
MAX_CALLS = int(ARGS[ARGS.index("--max-calls") + 1]) if "--max-calls" in ARGS else 60
POS = [a for i, a in enumerate(ARGS) if not a.startswith("--") and (i == 0 or ARGS[i - 1] != "--max-calls")]
RUNS = int(POS[0]) if POS else 3
MODEL = POS[1] if len(POS) > 1 else "qwen3.8-max"
CALLS = 0
KEY = os.environ["DASHSCOPE_API_KEY"].strip()
SEARCH_URL = "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
CHAT_URL = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
MAX_STEPS = 12
QUESTION = "11月25日到29日（2026年）珠海和澳门有什么展览、漫展、cosplay或AI活动？只要这几天开放的。"
SYSTEM = ("你是会上网查资料的助手，今天是2026年11月24日（周二），在珠海。你有两个工具：search 搜网页（返回标题、链接、摘要），"
          "open_page 打开一个链接读全文。像人一样查：换不同说法多搜几次，打开活动列表页、主办方页、票务页读原文，顺着页面里的链接继续找。"
          "日期只认你打开的页面里写的。查够了就只输出 JSON：{\"events\": [{\"name\": \"\", \"dates\": \"页面里写的日期原文\", "
          "\"start\": \"YYYY-MM-DD\", \"end\": \"YYYY-MM-DD\", \"place\": \"\", \"source_url\": \"你打开过的、写着这个日期的页面\"}], \"note\": \"\"}。没找到就 events 为空。")
TOOLS = [{"type": "function", "function": {"name": "search", "description": "搜索网页，返回最多10条结果（标题、链接、摘要）。",
           "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}},
         {"type": "function", "function": {"name": "open_page", "description": "打开一个网页链接，返回页面正文文字（最多6000字）和页面里的链接。",
           "parameters": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}}}]

def post(url, body, headers, timeout=120):
    global CALLS
    if CALLS >= MAX_CALLS: raise SystemExit(f"stopped at --max-calls {MAX_CALLS}")
    CALLS += 1
    req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json", **headers})
    for wait in (5, 15, 0):
        try:
            return json.load(urllib.request.urlopen(req, timeout=timeout))
        except Exception as e:
            if not wait: raise
            time.sleep(wait)

def search(query):
    msgs = [{"role": "user", "content": [{"text": query}]}]
    r = post(SEARCH_URL, {"model": "qwen3.8-flash", "input": {"messages": msgs},
                          "parameters": {"enable_search": True, "enable_thinking": False, "result_format": "message",
                                         "search_options": {"enable_source": True, "forced_search": True, "search_strategy": "max"}}},
             {"Authorization": f"Bearer {KEY}"})
    res = (r["output"].get("search_info") or {}).get("search_results", [])
    return [{"title": x.get("title"), "url": x.get("url"), "site": x.get("site_name")} for x in res][:10]

PAGES = {}
def open_page(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/130 Safari/537.36",
                                                   "Accept-Language": "zh-CN,zh;q=0.9"})
        raw = urllib.request.urlopen(req, timeout=20).read(2_000_000)
        enc = re.search(rb'charset=["\']?([\w-]+)', raw[:3000])
        doc = raw.decode(enc.group(1).decode() if enc else "utf-8", "ignore")
    except Exception as e:
        return {"error": str(e)[:200]}
    links = re.findall(r'<a[^>]+href="(https?://[^"]+)"[^>]*>(.*?)</a>', doc, re.S)
    links = [{"url": u, "text": re.sub(r"<[^>]+>|\s+", " ", t).strip()[:40]} for u, t in links if re.sub(r"<[^>]+>", "", t).strip()][:40]
    text = re.sub(r"(?is)<(script|style|noscript)[^>]*>.*?</\1>", " ", doc)
    text = html.unescape(re.sub(r"<[^>]+>", " ", text))
    text = re.sub(r"\s+", " ", text).strip()
    PAGES[url] = text
    return {"text": text[:6000], "links": links}

def norm_dates(s):
    """All Y-M-D forms found in a text, as YYYY-MM-DD, plus M-D without year (assume 2026)."""
    out = set()
    for y, m, d in re.findall(r"(20\d\d)\s*[年./-]\s*(\d{1,2})\s*[月./-]\s*(\d{1,2})", s):
        out.add(f"{y}-{int(m):02d}-{int(d):02d}")
    for m, d in re.findall(r"(?<!\d)(\d{1,2})\s*月\s*(\d{1,2})\s*日", s):
        out.add(f"2026-{int(m):02d}-{int(d):02d}")
    for m, d in re.findall(r"(?<![\d/.-])(\d{1,2})[./](\d{1,2})(?![\d/.])", s):
        if 1 <= int(m) <= 12 and 1 <= int(d) <= 31: out.add(f"2026-{int(m):02d}-{int(d):02d}")
    return out

def run_once(n):
    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": QUESTION}]
    steps = []
    for step in range(MAX_STEPS):
        r = post(CHAT_URL, {"model": MODEL, "messages": msgs, "tools": TOOLS, "enable_thinking": False}, {"Authorization": f"Bearer {KEY}"})
        m = r["choices"][0]["message"]
        msgs.append({k: v for k, v in m.items() if k in ("role", "content", "tool_calls")})
        calls = m.get("tool_calls") or []
        if not calls:
            return m.get("content") or "", steps
        for c in calls:
            args = json.loads(c["function"]["arguments"] or "{}")
            if c["function"]["name"] == "search":
                res = search(args.get("query", "")); steps.append(f"search: {args.get('query')} -> {len(res)} results")
            else:
                res = open_page(args.get("url", ""))
                steps.append(f"open: {args.get('url','')[:110]} -> {'ERROR ' + res['error'] if 'error' in res else str(len(PAGES.get(args.get('url',''), ''))) + ' chars'}")
            msgs.append({"role": "tool", "tool_call_id": c["id"], "content": json.dumps(res, ensure_ascii=False)})
    msgs.append({"role": "user", "content": "步数用完了，现在按要求只输出 JSON。"})
    r = post(CHAT_URL, {"model": MODEL, "messages": msgs, "enable_thinking": False}, {"Authorization": f"Bearer {KEY}"})
    return r["choices"][0]["message"].get("content") or "", steps

for n in range(RUNS):
    PAGES.clear(); t = time.time()
    final, steps = run_once(n)
    print(f"\n######## run {n+1} ({time.time()-t:.0f}s, {len(steps)} tool calls)")
    for s in steps: print("  ", s)
    try:
        data = json.loads(re.search(r"\{.*\}", final, re.S).group(0))
    except Exception:
        print("  final (not JSON):", final[:500]); continue
    for e in data.get("events", []):
        page = PAGES.get(e.get("source_url", ""), "")
        on_page = norm_dates(page)
        start, end = e.get("start", ""), e.get("end", "")
        overlaps = start <= "2026-11-29" and end >= "2026-11-25"
        verdict = ("NOT OPENED" if not page else
                   "DATES ON PAGE" if start in on_page and end in on_page else "DATES NOT ON PAGE")
        print(f"   EVENT {e.get('name')} | {e.get('dates')} | {start}..{end} | {e.get('place')}\n"
              f"         src={e.get('source_url')}\n         check: {verdict}; in 25-29 Nov: {overlaps}")
    print("   note:", data.get("note"))
