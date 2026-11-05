#!/usr/bin/env python3
"""F-18 §23 item 6 (T-046l): the PC comparison of Qwen search set-ups S0-S3.

Sends each question in questions.json 3 times to each set-up and writes results.csv (answer, sources, searched,
time, Alibaba error code, tokens) and summary.csv (per set-up: right count, searched count, median and slowest
time, cost per question at the Singapore search price). The owner marks each row right or wrong in the `right`
column of results.csv (y/n), then runs `run.py --summary-only` to recount.

The key comes only from the environment variable DASHSCOPE_API_KEY. It is put in the Authorization header and
nowhere else: never in a file, never printed. A set-up Alibaba refuses is recorded with its HTTP status and error
code, and is not worked around.

Usage:
  DASHSCOPE_API_KEY=... python3 scripts/search_eval/run.py [--setups S0,S1,S2,S3] [--runs 3] [--tz Asia/Shanghai]
  python3 scripts/search_eval/run.py --summary-only
"""
import argparse
import csv
import datetime
import json
import os
import re
import pathlib
import statistics
import sys
import time
import urllib.error
import urllib.request
from zoneinfo import ZoneInfo

HERE = pathlib.Path(__file__).resolve().parent
KEY_ENV = "DASHSCOPE_API_KEY"
RUNS = 3

# Endpoints (Singapore). Check each against the Alibaba docs on the day of the run (§23 "Not verified").
# `--base-url` replaces the host (e.g. a workspace domain); the paths stay.
DEFAULT_BASE = "https://dashscope-intl.aliyuncs.com"
MULTIMODAL_PATH = "/api/v1/services/aigc/multimodal-generation/generation"
COMPATIBLE_CHAT_PATH = "/compatible-mode/v1/chat/completions"
RESPONSES_PATH = "/compatible-mode/v1/responses"
MULTIMODAL = DEFAULT_BASE + MULTIMODAL_PATH
COMPATIBLE_CHAT = DEFAULT_BASE + COMPATIBLE_CHAT_PATH
RESPONSES = DEFAULT_BASE + RESPONSES_PATH

# Singapore search price, §23 sources: $10 per 1,000 calls. Token prices are not filled in (no source in §23).
SEARCH_USD_PER_CALL = 10 / 1000

SETUPS = {
    "S0": {"model": "qwen3.7-flash", "api": "multimodal", "system": "app"},
    "S1": {"model": "qwen3.7-flash", "api": "multimodal", "system": "freshprompt"},
    "S2": {"model": "qwen3.8-max", "api": "agent_max", "system": "freshprompt"},
    "S3": {"model": "qwen3.8-flash", "api": "responses", "system": "freshprompt"},
}

RESULT_FIELDS = ["setup", "question", "run", "model", "answer", "sources", "searched", "search_calls", "time_s",
                 "http_status", "error_code", "network_error", "tokens", "note", "right"]
# S2 uses the OpenAI-compatible API, which returns no search results: `searched` there comes only from
# usage.x_tools search counts.
NOTES = {"S2": "S2 (OpenAI-compatible API) returns no sources; searched is from usage.x_tools only"}

WEEKDAYS = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
WRITTEN = re.compile(r"\d{1,2}月\d{1,2}[日号]")
RELATIVE = [("大后天", 3), ("后天", 2), ("明天", 1), ("明日", 1), ("今天", 0), ("今日", 0)]


# ---- Prompt building ----

def app_system(today: datetime.date, zone: str) -> str:
    """S0: QwenWebSearchClient.instruction, copied as it is in the app (§17 + §19)."""
    date = f"{today.year}年{today.month}月{today.day}日"
    return (f"今天是{date}，{WEEKDAYS[today.weekday()]}，时区{zone}。必须联网搜索，不要凭记忆回答。用一两句中文回答，"
            "给出具体的数字、地点和日期。查不到就说查不到。回答要写明是哪一天（几月几号）。"
            "问题里写了日期就只回答那一天；找不到那一天的信息就说查不到。")


def fresh_date(today: datetime.date) -> str:
    """FreshPrompt's {current_date}: `Month DD, YYYY` (the notebook's strftime("%B %d, %Y"))."""
    return today.strftime("%B %d, %Y")


def user_message(query: str, words: str | None) -> str:
    """§23 item 5, as WebSearchExecutor.userMessage."""
    said = (words or "").strip()[:200]
    return f"query: {query}\n\nquestion: {said}\nanswer: " if said else f"question: {query}\nanswer: "


def date_rewrite(query: str, today: datetime.date) -> str:
    """§19 items 1-2 for relative words only: each 今天/明天/后天/大后天 gets （YYYY年M月D日） when all name one day."""
    found = []
    i = 0
    while i < len(query):
        hit = next(((w, o) for w, o in RELATIVE if query.startswith(w, i)), None)
        if hit:
            found.append((i + len(hit[0]), hit[1]))
            i += len(hit[0])
        else:
            i += 1
    if not found or len({o for _, o in found}) != 1 or WRITTEN.search(query):
        return query
    day = today + datetime.timedelta(days=found[0][1])
    mark = f"（{day.year}年{day.month}月{day.day}日）"
    out = query
    for end, _ in reversed(found):
        out = out[:end] + mark + out[end:]
    return out


def messages(setup: str, question: dict, today: datetime.date, zone: str) -> list[dict]:
    """Role/text pairs. S0: app system text. S1-S3: item 7 exactly, nothing else added."""
    message = user_message(date_rewrite(question["query"], today), question.get("words"))
    if SETUPS[setup]["system"] == "app":
        return [{"role": "system", "text": app_system(today, zone)}, {"role": "user", "text": message}]
    current = fresh_date(today)
    return [
        {"role": "system", "text": f"You are a helpful assistant. Answer as concisely as possible. Knowledge cutoff: {current}."},
        {"role": "user", "text": "What's today's date?"},
        {"role": "assistant", "text": f"Today is {current} in {zone}."},
        {"role": "user", "text": message},
    ]


def request(setup: str, msgs: list[dict], base: str = DEFAULT_BASE) -> tuple[str, dict, bool]:
    """(url, JSON body, streamed) for one set-up, per the §23 item 6 table."""
    cfg = SETUPS[setup]
    base = base.rstrip("/")
    if cfg["api"] == "multimodal":  # S0, S1: as QwenWebSearchClient.request
        return base + MULTIMODAL_PATH, {
            "model": cfg["model"],
            "input": {"messages": [{"role": m["role"], "content": [{"text": m["text"]}]} for m in msgs]},
            "parameters": {"result_format": "message", "incremental_output": True, "enable_thinking": False,
                           "enable_search": True,
                           "search_options": {"search_strategy": "turbo", "enable_source": True, "forced_search": True}},
        }, True
    if cfg["api"] == "agent_max":  # S2: agent_max needs thinking on and streaming
        return base + COMPATIBLE_CHAT_PATH, {
            "model": cfg["model"],
            "messages": [{"role": m["role"], "content": m["text"]} for m in msgs],
            "stream": True, "stream_options": {"include_usage": True},
            "enable_thinking": True, "enable_search": True,
            "search_options": {"search_strategy": "agent_max", "enable_source": True},
        }, True
    # S3: Responses API with web_search and web_extractor, thinking on (ignores search_strategy).
    return base + RESPONSES_PATH, {
        "model": cfg["model"],
        "input": [{"role": m["role"], "content": m["text"]} for m in msgs],
        "tools": [{"type": "web_search"}, {"type": "web_extractor"}],
        "enable_thinking": True,
    }, False


# ---- Transport ----

def http_post(url: str, headers: dict, body: bytes, timeout: float) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def headers(key: str, streamed: bool) -> dict:
    h = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    if streamed:
        h["X-DashScope-SSE"] = "enable"
    return h


# ---- Parsing ----

def objects(raw: bytes) -> list[dict]:
    """Each `data:` JSON object of a stream, or the whole body when it is one JSON object."""
    text = raw.decode("utf-8", "replace")
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            try:
                v = json.loads(line[5:].strip())
            except ValueError:
                continue
            if isinstance(v, dict):
                out.append(v)
    if not out:
        try:
            v = json.loads(text)
            if isinstance(v, dict):
                out.append(v)
        except ValueError:
            pass
    return out


def error_code(objs: list[dict]) -> str:
    for o in objs:
        err = o.get("error")
        code = o.get("code") or (err.get("code") if isinstance(err, dict) else None)
        if code:
            return str(code)
    return ""


def tokens(objs: list[dict]) -> str:
    total = ""
    for o in objs:
        u = o.get("usage") or (o.get("response") or {}).get("usage") or {}
        if isinstance(u, dict):
            t = u.get("total_tokens")
            if t is None and ("input_tokens" in u or "output_tokens" in u):
                t = (u.get("input_tokens") or 0) + (u.get("output_tokens") or 0)
            if t is not None:
                total = str(t)
    return total


def _count(d, *path) -> int:
    for k in path:
        d = d.get(k) if isinstance(d, dict) else None
    return d if isinstance(d, int) else 0


def x_tools_searches(o: dict) -> int:
    """usage.x_tools.search.count or usage.x_tools.web_search.count (top level or under `response`)."""
    best = 0
    for root in (o, o.get("response") if isinstance(o.get("response"), dict) else {}):
        for tool in ("search", "web_search"):
            best = max(best, _count(root, "usage", "x_tools", tool, "count"))
    return best


def parse(setup: str, raw: bytes) -> dict:
    """answer, sources (urls), searched (yes/no), search_calls, error_code, tokens."""
    objs = objects(raw)
    answer, sources, searched = "", [], False
    calls = 0
    api = SETUPS[setup]["api"]
    for o in objs:
        if api == "multimodal":
            out = o.get("output") or {}
            choices = out.get("choices") or []
            if choices:
                content = (choices[0].get("message") or {}).get("content")
                if isinstance(content, str):
                    answer += content
                elif isinstance(content, list):
                    answer += "".join(p.get("text", "") for p in content if isinstance(p, dict))
            results = (out.get("search_info") or {}).get("search_results") or []
            if results:
                sources = [r.get("url", "") for r in results]
            calls = max(calls, _count(o, "usage", "plugins", "search", "count"))
        elif api == "agent_max":
            for c in o.get("choices") or []:
                answer += (c.get("delta") or {}).get("content") or ""
            calls = max(calls, x_tools_searches(o))
        else:
            body = o.get("response", o)
            items = body.get("output") or []
            calls = max(calls, x_tools_searches(o), sum(1 for i in items if i.get("type") == "web_search_call"))
            for item in items:
                kind = item.get("type", "")
                if kind in ("web_search_call", "web_extractor_call"):
                    searched = True
                    for s in (item.get("action") or {}).get("sources") or []:
                        if s.get("url"):
                            sources.append(s["url"])
                if kind == "message":
                    for part in item.get("content") or []:
                        if part.get("type") == "output_text":
                            answer += part.get("text", "")
                            for a in part.get("annotations") or []:
                                if a.get("url") and a["url"] not in sources:
                                    sources.append(a["url"])
    if sources or calls:
        searched = True
    return {"answer": answer.strip(), "sources": " ".join(s for s in sources if s), "searched": "yes" if searched else "no",
            "search_calls": calls, "error_code": error_code(objs), "tokens": tokens(objs)}


# ---- Run and summary ----

def run(setups, questions, runs, today, zone, key, post=http_post, clock=time.monotonic, timeout=120.0,
        base=DEFAULT_BASE, on_row=lambda row: None) -> list[dict]:
    """Every row is handed to `on_row` as soon as it exists, so a crash keeps what was done."""
    rows = []
    for setup in setups:
        for q in questions:
            for n in range(1, runs + 1):
                url, body, streamed = request(setup, messages(setup, q, today, zone), base)
                start = clock()
                network = ""
                try:
                    status, raw = post(url, headers(key, streamed), json.dumps(body, ensure_ascii=False).encode("utf-8"), timeout)
                except Exception as e:  # network or timeout: the class name only, never a message
                    status, raw, network = 0, b"", type(e).__name__
                elapsed = round(clock() - start, 2)
                parsed = parse(setup, raw)
                row = {"setup": setup, "question": q["id"], "run": n, "model": SETUPS[setup]["model"],
                       "answer": parsed["answer"], "sources": parsed["sources"], "searched": parsed["searched"],
                       "search_calls": parsed["search_calls"], "time_s": elapsed, "http_status": status,
                       "error_code": parsed["error_code"], "network_error": network, "tokens": parsed["tokens"],
                       "note": NOTES.get(setup, ""), "right": ""}
                rows.append(row)
                on_row(row)
                print(f"{setup} {q['id']} run {n}: status {status} {parsed['error_code'] or network or 'ok'} {elapsed}s", flush=True)
    return rows


def summary(rows: list[dict]) -> list[dict]:
    out = []
    for setup in sorted({r["setup"] for r in rows}):
        mine = [r for r in rows if r["setup"] == setup]
        times = [float(r["time_s"]) for r in mine]
        searched = sum(1 for r in mine if r["searched"] == "yes")
        calls = sum(int(r.get("search_calls") or 0) for r in mine)
        out.append({"setup": setup, "model": mine[0]["model"], "rows": len(mine),
                    "right": sum(1 for r in mine if str(r.get("right", "")).strip().lower() in ("y", "yes", "1", "right")),
                    "marked": sum(1 for r in mine if str(r.get("right", "")).strip()),
                    "searched": searched, "search_calls": calls,
                    "refused": sum(1 for r in mine if r["error_code"]),
                    "network_errors": sum(1 for r in mine if r.get("network_error")),
                    "median_s": round(statistics.median(times), 2) if times else "",
                    "slowest_s": max(times) if times else "",
                    # Search fee only (counted search calls x the Singapore price, per question asked); no token cost.
                    "search_fee_only_usd_per_question": round(calls * SEARCH_USD_PER_CALL / len(mine), 4),
                    "note": NOTES.get(setup, "")})
    return out


def write_csv(path: pathlib.Path, rows: list[dict], fields: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)


def main(argv=None, env=os.environ, post=http_post, out_dir: pathlib.Path = HERE) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--setups", default="S0,S1,S2,S3")
    p.add_argument("--runs", type=int, default=RUNS)
    p.add_argument("--tz", default="Asia/Shanghai", help="the phone's time zone identifier")
    p.add_argument("--questions", default=str(HERE / "questions.json"))
    p.add_argument("--base-url", default=DEFAULT_BASE, help="API host, e.g. a workspace domain (paths are kept)")
    p.add_argument("--summary-only", action="store_true", help="recount summary.csv from a marked results.csv")
    a = p.parse_args(argv)
    results, summary_path = out_dir / "results.csv", out_dir / "summary.csv"
    if a.summary_only:
        with results.open(encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
    else:
        key = env.get(KEY_ENV, "")
        if not key:
            print(f"{KEY_ENV} is not set", file=sys.stderr)
            return 2
        setups = [s.strip() for s in a.setups.split(",") if s.strip()]
        unknown = [s for s in setups if s not in SETUPS]
        if unknown:
            print(f"unknown setups: {unknown}", file=sys.stderr)
            return 2
        questions = json.loads(pathlib.Path(a.questions).read_text(encoding="utf-8"))["questions"]
        today = datetime.datetime.now(ZoneInfo(a.tz)).date()
        with results.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=RESULT_FIELDS)
            w.writeheader()
            f.flush()

            def append(row):
                w.writerow(row)
                f.flush()
            rows = run(setups, questions, a.runs, today, a.tz, key, post=post, base=a.base_url, on_row=append)
    summ = summary(rows)
    write_csv(summary_path, summ, list(summ[0].keys()) if summ else ["setup"])
    for s in summ:
        print(", ".join(f"{k}={v}" for k, v in s.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
