#!/usr/bin/env python3
"""F-15b §4 item 6 evidence probe: send trip place names (model style and official) to 高德 text search, the
search the app uses, and record what 高德 returns and which place the app's TripNameMatch would pick.

Run on a machine with the 高德 Web服务 key (never commit it):
    AMAP_WEB_KEY=... python3 scripts/amap_trip_name_probe.py > amap_probe.tsv
"""
import json, os, re, sys, time, urllib.parse, urllib.request

NAMES = [  # (city, asked name)
    ("澳门", "路环安德鲁葡挞"), ("澳门", "安德鲁饼店"), ("澳门", "路环那家葡挞"), ("澳门", "澳门旅游塔"),
    ("澳门", "大三巴牌坊"), ("澳门", "官也街"), ("北京", "北京故宫"), ("北京", "故宫博物院"),
    ("北京", "八达岭长城"), ("北京", "南锣鼓巷"), ("杭州", "杭州西湖"), ("杭州", "西湖"), ("杭州", "灵隐寺"),
    ("杭州", "河坊街"), ("天津", "盘山"), ("天津", "盘山风景区"), ("广州", "白云山"), ("广州", "广州塔"),
    ("广州", "陈家祠"), ("青岛", "崂山"), ("青岛", "栈桥"), ("成都", "宽窄巷子"), ("成都", "大熊猫基地"),
    ("西安", "兵马俑"), ("西安", "回民街"), ("上海", "外滩"), ("上海", "城隍庙小吃"), ("深圳", "世界之窗"),
]

def norm(s):  # close to TranscriptText.normalize: lowercase, no spaces or punctuation
    return re.sub(r"[\s\W_]+", "", s.lower())

def accepts(asked, found):
    a, f = norm(asked), norm(found)
    return bool(a and f) and (a in f or f in a)

def main():
    key = os.environ.get("AMAP_WEB_KEY")
    if not key:
        sys.exit("set AMAP_WEB_KEY to the 高德 Web服务 key")
    print("city\tasked\tstatus\tcount\ttop5\tpicked\tcheck_shown")
    for city, asked in NAMES:
        q = urllib.parse.urlencode({"key": key, "keywords": asked, "city": city, "citylimit": "true",
                                    "offset": 5, "page": 1, "extensions": "base"})
        try:
            with urllib.request.urlopen("https://restapi.amap.com/v3/place/text?" + q, timeout=10) as r:
                d = json.load(r)
        except Exception as e:
            print(f"{city}\t{asked}\terror:{e}\t0\t\t\t"); continue
        names = [p.get("name", "") for p in d.get("pois", [])][:5]
        picked = next((n for n in names if accepts(asked, n)), names[0] if names else "")
        unsure = bool(picked) and not accepts(asked, picked)
        status = d.get("status") + ("" if d.get("status") == "1" else ":" + d.get("info", ""))
        print(f"{city}\t{asked}\t{status}\t{d.get('count', 0)}\t{' | '.join(names)}\t{picked}\t{'yes' if unsure else ''}")
        time.sleep(0.4)

if __name__ == "__main__":
    main()
