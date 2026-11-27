#!/usr/bin/env python3
"""F-09b §18 item 8 (T-031zc): PC check before the build, with real 高德 data.

Sends each case to 高德 Web服务 `v3/place/text` (city-limited, as `ShowPlaceTool` does) and applies the §18 rules:
sure = exactly one result whose name equals the asked name (spaces, case and a trailing bracket branch ignored)
and whose city is the asked city (a trailing 市 ignored). Prints sure/unsure and the found list (up to 5).

    AMAP_WEB_KEY=... python3 scripts/show_place_check.py --max-calls 4
    python3 scripts/show_place_check.py --dry-run      # no key, no network: prints the planned calls only

Paid-script rules (F-18 §32): prints the planned calls first, sends at most --max-calls, stops at the first quota
error. 高德 Web服务 counts against the key's daily quota; never commit the key.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

KEY_ENV = "AMAP_WEB_KEY"
URL = "https://restapi.amap.com/v3/place/text"
MAX_FOUND = 5

# §18 acceptance row 6: (name, city, expected)
CASES = [
    ("清远新世界酒店", "清远", "sure"),
    ("悦天下生态度假区", "云浮", "sure (or unsure with 悦天下 in found)"),
    ("悦天下生态度假区", "清远", "unsure"),
    ("鼓浪屿", "厦门", "sure"),
]

QUOTA_INFOCODES = {"10003", "10004", "10014", "10019", "10020", "10021", "10044", "10045"}


def same_name(s: str) -> str:
    t = re.sub(r"\s+", "", s.lower())
    m = re.match(r"^(.+?)[(（][^()（）]*[)）]$", t)
    return m.group(1) if m else t


def whole_name(s: str) -> str:
    return re.sub(r"\s+", "", s.lower()).replace("（", "(").replace("）", ")")


def same_city(s: str) -> str:
    t = re.sub(r"\s+", "", s)
    return t[:-1] if t.endswith("市") and len(t) > 1 else t


def judge(name: str, city: str, pois: list) -> tuple:
    """(sure, found): found is up to five {name, city, district, address}; sure is the one exact match or None."""
    def text(v):
        return v if isinstance(v, str) else ""
    found = [{"name": text(p.get("name")), "city": text(p.get("cityname")), "district": text(p.get("adname")),
              "address": text(p.get("address"))} for p in pois]
    asked = same_name(name)
    whole = whole_name(name)
    # A name with its branch (called again with a name from found) is compared whole, as the app does.
    key = (lambda n: whole_name(n) == whole) if whole != asked else (lambda n: same_name(n) == asked)
    hits = [f for f in found if asked and key(f["name"])
            and (not city or same_city(f["city"]) == same_city(city))]
    return (hits[0] if len(hits) == 1 else None), found[:MAX_FOUND]


def fetch(key: str, name: str, city: str) -> dict:
    q = urllib.parse.urlencode({"key": key, "keywords": name, "city": city, "citylimit": "true",
                                "offset": 10, "page": 1, "extensions": "base"})
    with urllib.request.urlopen(URL + "?" + q, timeout=10) as r:
        return json.load(r)


def main(argv=None, env=None, get=fetch) -> int:
    env = os.environ if env is None else env
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--max-calls", type=int, default=len(CASES), help="send at most this many 高德 requests")
    p.add_argument("--dry-run", action="store_true", help="print the planned calls; no key, no network")
    args = p.parse_args(argv)
    planned = CASES[:max(0, args.max_calls)]
    print(f"planned: {len(planned)} call(s) to {URL} (max-calls {args.max_calls})")
    for name, city, expected in planned:
        print(f"  {name} / {city}  expect {expected}")
    if args.dry_run:
        return 0
    key = env.get(KEY_ENV)
    if not key:
        print(f"set {KEY_ENV} to the 高德 Web服务 key (or use --dry-run)", file=sys.stderr)
        return 2
    for i, (name, city, expected) in enumerate(planned):
        try:
            d = get(key, name, city)
        except Exception as e:  # network unavailable: say so, do not guess
            print(f"{name}\t{city}\terror:{type(e).__name__}\texpect {expected}")
            continue
        if d.get("status") != "1":
            print(f"{name}\t{city}\tamap:{d.get('infocode')} {d.get('info')}\texpect {expected}")
            if str(d.get("infocode")) in QUOTA_INFOCODES:
                print("stopped: quota error", file=sys.stderr)
                return 1
            continue
        sure, found = judge(name, city, d.get("pois") or [])
        verdict = "sure" if sure else "unsure"
        listed = " | ".join(f"{f['name']} ({f['city']}{f['district']})" for f in found)
        print(f"{name}\t{city}\t{verdict}\tfound={len(d.get('pois') or [])}\t{listed}\texpect {expected}")
        if i + 1 < len(planned):
            time.sleep(0.3)
    return 0


if __name__ == "__main__":
    sys.exit(main())
