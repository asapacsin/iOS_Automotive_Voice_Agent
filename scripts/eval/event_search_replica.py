"""F-18 §39 row 55 (T-046zb): a PC replica of the app's events search (EventSearchRun), to run BEFORE an app build.
As the app does it: city x kind keyword queries (EventSearchRun.queries: at most 12, the Macau/Hong Kong English query
last), each on deepseek-v4.1-flash (F-18 §40: the search chain's first model) on the Responses API with the web_search tool (F-18 §41), thinking off, not streamed, the
query as the only user message and no system text, 4 at once, 45 s each; then one qwen3.8-max-0902 extraction call (§40: the text chain's first)
(compatible mode, json_object, system 「Extract the event information. Answer in JSON.」 + the shape, today and the window); then
code's checks (dates parse, end >= start, overlaps the window, end >= today, city one of the asked, source_url one the
searches returned else the naming query's first source, name+start once).
Bar (row 55): each run finds >= 60% of the CONFIRMED reference events (scripts/eval/events_reference_2026-11.json) with
the right start date, and no kept event outside the window; median <= 60 s and <= 25K flash tokens.
Usage: python -I -X utf8 event_search_replica.py [runs] [--max-calls N] [--yes] [--qiniu]
F-18 §42 item 7 (T-046ze): --qiniu (key QINIU_API_KEY) runs §42 items 2-4 exactly: 3 Qiniu searches naming every city,
all at once, max_results 20, 15 s; extraction on deepseek/deepseek-v4-flash-20260731 over the numbered results, 60 s.
Bar (row 74): >= 3/7 reference events in each run; extraction <= 60 s.
Paid calls (F-18 §32 item 6): each search and each extraction counts; stops at --max-calls (default 40)."""
import concurrent.futures as cf, datetime as dt, json, os, pathlib, statistics, sys, time, urllib.request

ARGS = sys.argv[1:]
MAX_CALLS = int(ARGS[ARGS.index("--max-calls") + 1]) if "--max-calls" in ARGS else 40
POS = [a for i, a in enumerate(ARGS) if not a.startswith("--") and (i == 0 or ARGS[i - 1] != "--max-calls")]
RUNS = int(POS[0]) if POS else 3
CALLS = 0
# F-18 §40 items 1, 4: the Beijing 百炼 account (key DASHSCOPE_API_KEY_CN) and its free-quota models.
# F-18 §41 item 6: the search jobs send to the Responses API with the web_search tool, as the app does.
SEARCH_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1/responses"
CHAT_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
SEARCH_MODEL, EXTRACT_MODEL = "deepseek-v4.1-flash", "qwen3.8-max-0902"
CITIES, FROM, TO, TODAY = ["珠海", "澳门", "横琴"], "2026-11-25", "2026-12-31", "2026-11-24"
DEFAULT_KINDS = ["展览展会", "漫展 ACG", "演唱会 演出", "AI 科技展", "节庆活动"]
ENGLISH = {"澳门": "Macau", "香港": "Hong Kong"}
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
SHAPE = ('{"events": [{"name": "", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD", "dates_text": "", "venue": "", '
         '"city": "", "source_url": ""}]}')
REFERENCE = pathlib.Path(__file__).with_name("events_reference_2026-11.json")


def queries(cities, frm, to, kinds=DEFAULT_KINDS):
    f, t = dt.date.fromisoformat(frm), dt.date.fromisoformat(to)
    months, y, m = [], f.year, f.month
    while len(months) < 3 and (y, m) <= (t.year, t.month):
        months.append((y, m))
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    when = f"{months[0][0]}年{months[0][1]}月" + "".join(f" {mm}月" for _, mm in months[1:])
    out = [(f"{c} {k} {when}", c, k) for c in cities for k in kinds]
    out += [(f"{ENGLISH[c]} events exhibition concert {MONTHS[f.month - 1]} {f.year}", c, None) for c in cities if c in ENGLISH]
    return out[:12], max(0, len(out) - 12)


QINIU = "--qiniu" in ARGS
TAVILY = "--tavily" in ARGS  # PoC 2026-11-26: the §42 three searches on Tavily, extraction on the Beijing text model
TAVILY_URL = "https://api.tavily.com/search"
# Wording G of tavily_recall.py (7/7 reference events in the results on two tries, 2026-11-26).
TAVILY_QUERIES = ["珠海 横琴 澳门 2026年11月 12月 展览展会 AI 科技展 航展", "澳门 2026年11月 12月 演唱会 演出时间表 FANCON",
                  "珠海 横琴 2026年11月 12月 演唱会 嘉年华 电音节 马拉松"]
SHAPE_T = ('{"events": [{"name": "", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD", "start_time": "HH:MM or empty", '
           '"venue": "", "city": "", "ticket": "", "source_url": ""}]}')
QINIU_SEARCH_URL = "https://api.qnaigc.com/v1/search/web"
QINIU_CHAT_URL = "https://api.qnaigc.com/v1/chat/completions"
QINIU_MODEL = "deepseek/deepseek-v4-flash-20260731"
QINIU_GROUPS = ["展览展会 科技展", "演唱会 演出", "漫展 节庆 嘉年华"]


def qiniu_queries(cities, frm, to):
    """§42 item 4: one query per kind group, every city named, no English query."""
    f, t = dt.date.fromisoformat(frm), dt.date.fromisoformat(to)
    months, y, m = [], f.year, f.month
    while len(months) < 3 and (y, m) <= (t.year, t.month):
        months.append((y, m))
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    when = f"{months[0][0]}年{months[0][1]}月" + "".join(f" {mm}月" for _, mm in months[1:])
    head = " ".join(cities + [when])
    return [(f"{head} {g}", cities[0], g) for g in QINIU_GROUPS], 0


def qiniu_search(q, key):
    """§42 item 2: plain results (title, url, content, date, source); the titles and snippets stand in for the answer."""
    t0 = time.time()
    r = post(QINIU_SEARCH_URL, {"query": q, "max_results": 20, "search_type": "web"}, key, 15)
    if not r.get("success"):
        raise RuntimeError("qiniu search success=false")
    res = [x for x in (r.get("data") or {}).get("results", []) if x.get("url")]
    sources = [{"title": x.get("title", ""), "url": x["url"], "content": x.get("content", ""), "date": x.get("date", "")} for x in res]
    ms = int((time.time() - t0) * 1000)
    print(f"  search ms={ms} results={len(sources)} q={q}")
    return {"text": "\n".join(s["title"] + " " + s["content"] for s in sources), "sources": sources, "tokens": 0, "ms": ms}


def tavily_search(q, key):
    """Same output shape as qiniu_search: Tavily results, 20 at most, basic depth."""
    t0 = time.time()
    r = post(TAVILY_URL, {"query": q, "max_results": 20, "search_depth": "basic"}, key, 30)
    sources = [{"title": x.get("title", ""), "url": x["url"], "content": x.get("content", ""), "date": x.get("published_date") or ""}
               for x in r.get("results", []) if x.get("url")]
    ms = int((time.time() - t0) * 1000)
    print(f"  search ms={ms} results={len(sources)} q={q}")
    return {"text": "\n".join(s["title"] + " " + s["content"] for s in sources), "sources": sources, "tokens": 0, "ms": ms}


def tavily_extract(answers, key):
    """The §42 extraction (numbered results, json_object) on the Beijing text model."""
    system = f"Extract the event information. Answer in JSON.\n{SHAPE}\ntoday: {TODAY}\nfrom: {FROM}\nto: {TO}"
    nums = qiniu_numbered(answers)
    user = "\n".join(f"[{n + 1}] {s['date']} {s['title']} — {s['content'][:300]} ({s['url']})" for n, s in enumerate(nums))
    t0 = time.time()
    r = post(CHAT_URL, {"model": EXTRACT_MODEL, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                        "response_format": {"type": "json_object"}, "enable_thinking": False, "stream": False}, os.environ["DASHSCOPE_API_KEY_CN"].strip(), 60)
    u = r.get("usage", {})
    print(f"  extract ms={int((time.time() - t0) * 1000)} tokens={u.get('prompt_tokens', 0)},{u.get('completion_tokens', 0)}")
    events = json.loads(r["choices"][0]["message"]["content"]).get("events", [])
    for e in events:
        d = str(e.get("source_url", "")).strip("[] ")
        if d.isdigit() and 1 <= int(d) <= len(nums):
            e["source_url"] = nums[int(d) - 1]["url"]
    return events, u.get("total_tokens", 0)


def qiniu_numbered(answers):
    seen, out = set(), []
    for _, a in answers:
        for s in a["sources"]:
            if s["url"] not in seen:
                seen.add(s["url"]); out.append(s)
    return out


def qiniu_extract(answers, key):
    """§42 item 4: the §39 system text; one numbered line per result; json_object; 60 s."""
    system = f"Extract the event information. Answer in JSON.\n{SHAPE}\ntoday: {TODAY}\nfrom: {FROM}\nto: {TO}"
    user = "\n".join(f"[{n + 1}] {s['date']} {s['title']} — {s['content'][:300]} ({s['url']})" for n, s in enumerate(qiniu_numbered(answers)))
    t0 = time.time()
    r = post(QINIU_CHAT_URL, {"model": QINIU_MODEL, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                              "response_format": {"type": "json_object"}, "stream": False}, key, 60)
    u = r.get("usage", {})
    reasoning = (u.get("completion_tokens_details") or {}).get("reasoning_tokens", 0)
    print(f"  extract ms={int((time.time() - t0) * 1000)} tokens={u.get('prompt_tokens', 0)},{u.get('completion_tokens', 0)},{reasoning}")
    events = json.loads(r["choices"][0]["message"]["content"]).get("events", [])
    nums = qiniu_numbered(answers)
    for e in events:  # §42 item 4: a source_url that names a result number is that result's url
        d = str(e.get("source_url", "")).strip("[] ")
        if d.isdigit() and 1 <= int(d) <= len(nums):
            e["source_url"] = nums[int(d) - 1]["url"]
    return events, u.get("total_tokens", 0)


RAW_DIR = pathlib.Path(os.environ.get("NOVA_RAW_DIR", "D:/ndlogs/search-raw"))
RAW_FILE = RAW_DIR / f"{dt.datetime.now():%Y%m%d-%H%M%S}-event_search_replica.jsonl"


def keep_raw(url, body, response):
    """Owner rule 2026-11-26: every paid call's request (no key) and full response is kept on disk."""
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    with RAW_FILE.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"at": dt.datetime.now().isoformat(timespec="seconds"), "url": url, "request": body,
                            "response": response}, ensure_ascii=False) + "\n")


def post(url, body, key, timeout):
    global CALLS
    if CALLS >= MAX_CALLS:
        raise SystemExit(f"stopped at --max-calls {MAX_CALLS}")
    CALLS += 1
    req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    try:
        r = json.load(urllib.request.urlopen(req, timeout=timeout))
        keep_raw(url, body, r)
        return r
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "ignore")
        keep_raw(url, body, {"http_status": e.code, "body": text})
        # §39 item 3 (amended 2026-11-25): print the error body of a non-200 answer.
        print(f"{'events extract' if url == CHAT_URL else 'events query'} failed status={e.code} body={text[:300]}")
        if e.code == 429 or "Quota" in text:
            raise SystemExit(f"quota/rate error {e.code}: stopping (F-18 §32 item 6)")
        raise


def search(q, key):
    t0 = time.time()
    r = post(SEARCH_URL, {"model": SEARCH_MODEL, "input": [{"role": "user", "content": q}],
                          "tools": [{"type": "web_search"}], "enable_thinking": False}, key, 45)
    # §41 item 3: answer = output_text of the message items; sources = web_search_call action.sources urls, deduplicated.
    items = r.get("output") or []
    text = "".join(c.get("text", "") for it in items if it.get("type") == "message"
                   for c in it.get("content") or [] if c.get("type") == "output_text")
    urls = []
    for it in items:
        if it.get("type") == "web_search_call":
            for x in (it.get("action") or {}).get("sources") or []:
                if x.get("url") and x["url"] not in urls:
                    urls.append(x["url"])
    sources = [{"title": "", "url": u} for u in urls]
    u = r.get("usage", {})
    return {"text": text, "sources": sources, "tokens": u.get("total_tokens") or u.get("input_tokens", 0) + u.get("output_tokens", 0),
            "ms": int((time.time() - t0) * 1000)}


def extract(answers, key):
    system = f"Extract the event information. Answer in JSON.\n{SHAPE}\ntoday: {TODAY}\nfrom: {FROM}\nto: {TO}"
    user = "\n\n".join(f"## {i + 1}. {q}\n{a['text']}\n" + "\n".join(f"[{n + 1}] {s['title']} {s['url']}" for n, s in enumerate(a["sources"]))
                       for i, (q, a) in enumerate(answers))
    r = post(CHAT_URL, {"model": EXTRACT_MODEL, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                        "response_format": {"type": "json_object"}, "enable_thinking": False, "stream": False}, key, 30)
    return json.loads(r["choices"][0]["message"]["content"]).get("events", []), r.get("usage", {}).get("total_tokens", 0)


def city_of(text):
    for alias, c in {"Macau": "澳门", "Macao": "澳门", "澳門": "澳门", "Hong Kong": "香港"}.items():
        if alias.lower() in (text or "").lower():
            text = c
    return next((c for c in CITIES if text and (c in text or text in c)), None)


def check(cands, answers):
    kept, dropped, seen = [], 0, set()
    all_urls = {s["url"] for _, a in answers for s in a["sources"]}
    for c in cands:
        try:
            s, e = dt.date.fromisoformat(c.get("start", "")), dt.date.fromisoformat(c.get("end") or c.get("start", ""))
        except ValueError:
            dropped += 1; continue
        city = city_of(c.get("city", ""))
        ok = s <= e and s <= dt.date.fromisoformat(TO) and e >= dt.date.fromisoformat(FROM) and e >= dt.date.fromisoformat(TODAY) and city
        url = c.get("source_url", "")
        if url not in all_urls:
            naming = next((a for _, a in answers if c.get("name") and c["name"] in a["text"] and a["sources"]), None)
            url = naming["sources"][0]["url"] if naming else ""
        key = (c.get("name"), c.get("start"))
        if not ok or not url or key in seen:
            dropped += 1; continue
        seen.add(key)
        kept.append({**c, "city": city, "source_url": url})
    return kept, dropped


def main():
    ref = json.loads(REFERENCE.read_text(encoding="utf-8"))
    confirmed = [e for e in ref["events"] if e.get("confirmed")]
    if not confirmed:
        raise SystemExit("no confirmed reference event: confirm events_reference_2026-11.json by hand first (row 55)")
    qs, cut = ([(q, CITIES[0], None) for q in TAVILY_QUERIES], 0) if TAVILY else qiniu_queries(CITIES, FROM, TO) if QINIU else queries(CITIES, FROM, TO)
    planned = RUNS * (len(qs) + 1)
    print(f"planned paid calls: {planned} ({RUNS} runs x {len(qs)} searches + 1 extraction); --max-calls {MAX_CALLS}")
    if "--yes" not in ARGS and input("start? [y/N] ").strip().lower() != "y":
        return 1
    key = os.environ["TAVILY_API_KEY" if TAVILY else "QINIU_API_KEY" if QINIU else "DASHSCOPE_API_KEY_CN"].strip()
    do_search, do_extract = (tavily_search, tavily_extract) if TAVILY else (qiniu_search, qiniu_extract) if QINIU else (search, extract)
    results = []
    for run in range(RUNS):
        t0 = time.time()
        with cf.ThreadPoolExecutor(len(qs) if QINIU or TAVILY else 4) as pool:
            futs = {pool.submit(do_search, q, key): q for q, _, _ in qs}
            answers, failed = [], 0
            for f in cf.as_completed(futs):
                try:
                    answers.append((futs[f], f.result()))
                except SystemExit:
                    raise
                except Exception:
                    failed += 1
        answers.sort(key=lambda qa: [q for q, _, _ in qs].index(qa[0]))
        tx = time.time()
        cands, xtok = do_extract(answers, key)
        xsecs = time.time() - tx
        kept, dropped = check(cands, answers)
        secs = time.time() - t0
        tokens = sum(a["tokens"] for _, a in answers) + xtok
        found = [r for r in confirmed if any(r["name_key"] in k.get("name", "") and k.get("start") == r["start"] for k in kept)]
        outside = [k for k in kept if k["end"] < FROM or k["start"] > TO]
        recall = len(found) / len(confirmed)
        results.append((recall, secs, tokens, outside, xsecs, len(found)))
        print(f"run {run + 1}: queries={len(qs)} cut={cut} failed={failed} kept={len(kept)} dropped={dropped} "
              f"recall={recall:.0%} ({len(found)}/{len(confirmed)}) outside={len(outside)} s={secs:.1f} tokens={tokens}")
        for k in kept:
            print(f"  {k['start']}..{k['end']} {k.get('start_time') or '-'} {k['city']} {k['name']} @ {k.get('venue') or '-'} | {k.get('ticket') or '-'} | {k['source_url']}")
    med_s = statistics.median(x[1] for x in results)
    med_t = statistics.median(x[2] for x in results)
    if QINIU or TAVILY:
        ok = all(x[5] >= 3 and x[4] <= 60 for x in results)
        print("ROW 74", "PASS" if ok else "FAIL", f"median s={med_s:.1f}", f"median tokens={med_t}")
        return 0 if ok else 1
    ok = all(x[0] >= 0.6 and not x[3] for x in results) and med_s <= 60 and med_t <= 25000
    print("ROW 55", "PASS" if ok else "FAIL", f"median s={med_s:.1f}", f"median tokens={med_t}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
