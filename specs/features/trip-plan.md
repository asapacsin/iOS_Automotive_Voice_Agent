# F-15b Trip list and multi-stop route (打卡清单 → 串成路线 → 途经点导航)

**Status:** APPROVED for phases 1 and 2 (owner 2026-11-16: phase 1 "good then you just write a spec and push to
remot"; phase 2 "you just create a spec including this function and also other thing that tailored from the movie
and push to remtoe", after the community review of poster cards, screen editing and saved plans). iOS only.
Phase 1 (§3–§9) is voice only. Phase 2 (§11–§17) adds the poster cards, editing on screen, map pins, saved plans
and days. Phase 3 (§25–§34, T-040n) replaces the 途经点 trip route with a plan ordered by location and one stop at a time.
Phase 4 (§35–§44, T-040o) adds trips abroad (Apple place search), a start, hotels and an end.
**Depends on:** F-15 (navigation flow, `NaviEngine`, `RouteRequest`), F-15a §2.5 and §9 (start on the recommended
route, no start guard, one trip at a time), F-16 (`PlaceSearch`, origin rule), F-09 (catalog, dispatch,
argument validation), F-06 (reply pipeline), contracts/navigation.md, contracts/api-contracts.md (Amap)

## 1. Why

The owner's video `11-16_compressed.mp4` (2026-11-16) is a 6-minute 豆包 car demo:
1. 「规划天津三天的行程」 gives a day-by-day plan.
2. 「做个打卡清单」 turns it into a list.
3. The list is shown on the map.
4. 「串成自驾路线」 chains 8 stops into one route (156 km, 4 h 4 min).
5. 「开始导航」 starts guidance.
6. The map shows 途经1–8.

The assistant carries the list across six turns, and "the second one" means a real place.

NovaDrive (code at a429e99, after F-09b) can only take one destination:
- `navigate_to` → pick → route → guidance.
- `RouteRequest` holds only `destination` and `destinationName`.
- `AmapRouteEngine.fetch` sends only `origin` and `destination` to `/v3/direction/driving`.
- Nothing keeps a list of places between turns. The model's memory is the only "list". F-09b §6 (T-016p) carries a
  short summary of the last 6 exchanges into a new session, 60 characters each, but no place list and no coordinates.
- Nothing shows a list on screen, and nothing is saved on the phone.

## 2. Sources

- **The model proposes, map data grounds it.**
  - LLM travel planners leave locations and routing to map services. The model chooses places and the order is
    computed outside the model ([LLMAP, arXiv 2509.12273](https://arxiv.org/pdf/2509.12273v1),
    [RouteLLM, arXiv 2510.06078](https://arxiv.org/pdf/2510.06078v1),
    [Vaiage, arXiv 2505.10922](https://arxiv.org/abs/2505.10922)).
  - Tool-calling travel agents run "find places" and "build route" as app functions
    ([SerpApi travel agent](https://serpapi.com/blog/building-ahead-a-multi-tool-ai-travel-agent-with-openai-serpapi.md)).
- **The app keeps the list.**
  - Gemini Live keeps function results only in the session context
    ([Gemini Live tools](https://ai.google.dev/gemini-api/docs/live-api/tools)).
  - A session restart (F-05) loses it. So the app owns the numbered list and resolves ordinals itself, as F-15
    already does for its choice list.
- **Cars.**
  - 豆包 hands a planned trip to the car's navigation ([IT之家](https://www.ithome.com/0/963/725.htm)).
  - Production cars advertise adding and reordering stops and re-routing during the drive
    ([凤凰科技](https://tech.ifeng.com/c/8wUZh3XVsFj)). That part is phase 3.
- **高德 limit (read 2026-11-16).** The `/v3/direction/driving` page (last updated 2026-02-02) defines `waypoints`:
  - 「最大数目：16个坐标点。如果输入多个途径点，则按照用户输入的顺序进行路径规划」.
  - Points are `lng,lat`, at most 6 decimals, separated by `;`.
  - The v5 page also says 「最大支持16个途经点」.
  - Neither page has a per-leg object. A path's `distance` and `duration` cover the whole trip.
  - Source: [高德 路径规划](https://lbs.amap.com/api/webservice/guide/api/direction).

## 3. The trip list (`TripList`, pure, NovaCore)

1. **What it is.**
   - An ordered list of 1–16 stops. Each stop has a 1-based `index`, the name asked, and the resolved `Place`: id,
     name, address, coordinate, district and distance from the origin.
   - One list per app, owned by the app next to the navigation controller (F-15a §9). It survives voice sessions.
2. **Lifetime.**
   - `make_trip_list` replaces the list.
   - `edit_trip_list` `clear` empties it.
   - An app restart empties it in phase 1. Phase 2 saves it on the phone (§14), so a restart keeps it.
   - `navigate_to` and `exit_navigation_mode` leave it unchanged.
3. **Indexes.**
   - After every change, indexes are renumbered 1…n in list order.
   - `route_trip` with `order=nearest` reorders the list itself (§5 item 2). So 「第二个」 always means the second stop
     she last listed.
4. **Generation.** Every change raises the list's generation. A resolve that finishes after a newer change is
   dropped: it returns `OPTIONS_STALE` and changes nothing.

## 4. Resolving names

1. **The model's names are looked up on 高德**, never taken as places. Each name goes through
   `PlaceSearch.text(name, city:, cityLimit:)`:
   - `city` is the tool's `city` argument when given (`cityLimit: true`);
   - otherwise no city, as for `navigate_to` text search.
2. **Choice rule** (owner 2026-11-17, replaces the name match): a text model picks among 高德's results (item 6).
   No name rule of the app's own decides which result is the place.
3. **Duplicates.** A result whose `Place.id` is already in the list is dropped. Its name is reported in `duplicates`.
4. **Limits.**
   - At most 2 lookups run at once (item 7; was 4).
   - Each lookup uses the transport's 8 s timeout.
   - The whole `make_trip_list` call finishes within 15 s. Lookups still running then count as not found, with
     `reason=timeout` in the record.
5. **No key.** A missing or rejected key returns `AMAP_WEB_KEY_MISSING`. Any other lookup failure counts as not found
   (after item 7's retries).
6. **Qwen picks the place** (owner 2026-11-17; replaces the name rules of reviews 1–4 and the `check` field).
   - **Evidence** (probe 2026-11-17, `scripts/amap_trip_name_probe.py`, 28 names, the app's request with `city` and
     `citylimit=true`): 高德 returned results for all 28, and its first result was the right place for 26. The model's
     everyday names do not contain 高德's official names (「北京故宫」 vs 「故宫博物院」, 「兵马俑」 vs 「秦始皇兵马俑博物馆」),
     so any rule that compares the two texts rejects or skips right answers: the contain rule took
     「北京故宫博物院北院区(建设中)」 over 「故宫博物院」. The two wrong first results were a vague name (「路环那家葡挞」 →
     「不是葡挞」) and a station ranked first (「陈家祠」 → 「陈家祠(地铁站)」).
   - **Pattern** (community): the voice model talks; a text model does the work behind the tool
     ([OpenAI realtime agents, chat-supervisor](https://github.com/openai/openai-realtime-agents),
     [LiveKit subagent delegation](https://docs.livekit.io/agents/logic/patterns/subagent-delegation/)); candidates
     go to a model that chooses, rather than taking the first API result
     ([SpatialWebAgent, ACL 2025 demo](https://preview.aclanthology.org/display_plenaries/2025.acl-demo.25.pdf));
     高德's own MCP search returns the whole list for the model to choose
     ([amap-mcp-server maps_text_search](https://glama.ai/mcp/servers/sugarforever/amap-mcp-server/tools/maps_text_search)).
   - **Flow.**
     1. Each name: 高德 text search as item 1, the top 5 results kept (`TripTuning.candidates`).
     2. One result: taken. None: not found (`nomatch`). Two or more: the name goes to the picker.
     3. **One picker call per tool call**, for every name with two or more results: `PlacePicker.pick` (NovaPorts),
        implemented by `QwenPlacePicker` (NovaRealtime): `qwen3.7-flash`, the same endpoint and Keychain key as
        `QwenWebSearchClient`, `enable_search=false`, `enable_thinking=false`, not streamed.
     4. **Prompt, copied:** EntGPT's multiple-choice form ([arXiv 2402.06738](https://arxiv.org/pdf/2402.06738v2)):
        per name, the mention with its city, the numbered candidates (name, address, district) and a "None of the
        above" option, under EntGPT's instruction 「Select the entity which best describes the mention」. Answer: one
        line per name, `name number: option number`, `0` for none. OneNet's advice to use the place clues in the
        context ([arXiv 2410.07549](https://arxiv.org/pdf/2410.07549)) is met by sending the city and each candidate's
        address. Copied verbatim: the instruction sentence (EntGPT-I's instruction-tuning instruction). Our own
        layout around it: `Mention n:`, `(city: …)`, ` — address, district`, `(0) None of the above` (EntGPT writes
        its none option as the last number) and the answer format.
     5. **Answer used:** the chosen result; "none" → not found with record reason `none`.
     6. **Fallback:** no Qwen key, an error, an unreadable answer, or no answer within **2.5 s** (`TripTuning.pickLimit`,
        Ultravox's default tool timeout, [docs](https://docs.ultravox.ai/tools/async-tools)): every open name takes
        高德's first result. A list is never blocked by the picker.
   - **Cache:** a place that was the only result or the picker's choice is cached by city and asked name (item 7), so
     a cached name is neither searched nor picked again. A fallback first result is not cached: the next list asks
     again.
   - **Removed:** `TripNameMatch`, the `check` field and its `next` note, and the catalog lines about `check`. The
     catalog still asks for shop and official names (「安德鲁饼店」), which help both 高德 and the picker.
   - **Record:** `trip pick names=<n> none=<n> ok=<yes|no> ms=<n>`; `ok=no` with `reason=<nokey|timeout|failed|cancelled>`.
     Codes and numbers only (I-8).
   - The Qwen prompt is not the search prompt, but it is copied all the same (owner rule: review the community first).
7. **高德's request limits** (device 2026-11-17: 2 of 5 lookups failed with 4 at once). 高德's error codes 10019–10021
   mean the per-second limit was exceeded: requests over it are rejected, those within it still answer
   ([错误码说明](https://lbs.amap.com/api/webservice/guide/tools/info)). The per-second limit of a key is shown only in
   its console ([流量限制说明](https://lbs.amap.com/api/webservice/guide/tools/flowlevel)); a personal key has 5,000
   basic searches a month ([基础服务配额](https://lbs.amap.com/upgrade#price#base_service_price)). Common practice:
   fewer requests at once, retry with growing waits, cache results. So:
   - at most 2 lookups at once (was 4);
   - a lookup refused as busy (`quota`), timed out or failed is tried up to twice more, after 600 ms and then
     1.2 s, all inside the 15 s limit; `nomatch` is never retried;
   - places found are cached for the app's lifetime by city and asked name, at most 64, oldest dropped, so a
     re-made plan or a re-added stop costs no lookup;
   - record reasons: `nomatch`, `busy`, `timeout`, `failed`.
8. **Community review (2026-11-17, owner asked).** What published practice does, against items 6 and 7.
   - **Request limits.** Vendor guides agree on five points:
     - bound concurrency with a semaphore or token bucket
       ([CometAPI](https://apidoc.cometapi.com/zh-Hans/guides/rate-limits-and-concurrency),
       [阿里云客户端限流](https://help.aliyun.com/zh/redis/use-cases/client-side-throttling));
     - retry with exponential backoff, capped attempts, plus random jitter so retries do not fire together
       ([Prismatic](https://prismatic.io/blog/how-do-i-implement-exponential-backoff-with-jitter/),
       [Docebo](https://developer.docebo.com/docs/best-practices-for-handling-api-rate-limits-and-429-errors));
     - retry only throttle errors, not other refusals (阿里云 above);
     - cache stable results and send requests only when needed
       ([Google Maps: optimize web services](https://developers.google.com/maps/optimize-web-services?hl=zh-tw),
       [Truto](https://truto.one/blog/best-practices-for-handling-api-rate-limits-and-retries-across-multiple-third-party-apis/));
     - avoid nested retries.

     高德 publishes no retry advice.
     - Item 7 has: the concurrency bound, capped growing waits, the cache, and one retry layer.
     - **Gap 1:** no jitter.
     - **Gap 2:** the daily or per-minute blocks (10003, 10004, 10044, 10045) are mapped to `quota` like the
       per-second codes, so they are retried although a retry cannot succeed (it costs about 2 s more).
       - **Expected use** (owner, 2026-11-17: use stays small). A personal key has about 5,000 basic searches a month,
         about 160 a day (item 7).
         - A 2–3 day plan costs about 10–16 lookups (one per stop).
         - An added or swapped stop costs 1.
         - A cached place costs 0.
         - Another voice place search costs about 1.

         A heavy day is about 50–80 searches, so the daily block is not expected in normal use. Only a lookup loop or a
         shared key would reach it.
       - **Decision:** gap 2 is not built; it only makes a failure on a blocked day about 2 s slower, never a wrong
         answer.
       - **Unknown:** whether 高德 counts the requests it refused as over the per-second limit against the monthly
         total; if so, it adds a few per plan.
   - **Name match.** A review of POI matching methods ([arXiv 2310.15320](https://arxiv.org/pdf/2310.15320)) groups
     name similarity into four kinds: direct string comparison, preprocessing then scoring, phonetic, and embeddings.
     A study of Chinese POI data ([MDPI IJGI 13(4) 138](https://www.mdpi.com/2220-9964/13/4/138/html)) finds name,
     location and category together match best, better than name alone. Tools such as
     [fuzzychinese](https://pypi.tcis.de/data/web/json/fuzzychinese) do fuzzy matching on Chinese proper names.
     - Item 6 is "preprocessing then scoring": it removes regions and place-type words, then requires a shared run of
       at least 3 characters.
     - **Gap 3:** only the name is checked. Location is bounded only by `cityLimit` when a city is given, and the
       place type (food vs. sight) is not compared.
   - Gap 2 is skipped (decision above). Gaps 1 and 3 are not built yet; they wait for the owner's go-ahead.

9. **Runs in the background** (owner 2026-11-17). `make_trip_list` and `edit_trip_list` join `AsyncTool`: declared
   `behavior: NON_BLOCKING`, answered with `scheduling: WHEN_IDLE`, as `web_search` and `query_live_info` already are
   (F-18 §27; Gemini Live
   [asynchronous function calling](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/live-api/asynchronous-function-calling)).
   - She says one short line (「好，我排一下」) and keeps talking; when the result comes back she explains it once the
     driver is quiet.
   - **Waiting for the list:** `route_trip` and `trip_plans` wait until no `make_trip_list` or `edit_trip_list` is
     running (including one that starts while they wait), then use the finished list. `edit_trip_list` (a spoken
     change or a card tap) waits for a running `make_trip_list`, so an edit never makes a new list stale. A new
     `make_trip_list` waits for nothing: it still replaces a running change (§3 item 4, row 6).
   - Catalog line on both tools: 「结果稍后回来：先只说一句在排，结果回来前不要说清单里有什么。」
   - **Not verified:** that `gemini-3.8-live` honours `WHEN_IDLE` for these tools on the device (device row).

## 5. Tools (F-09 catalog)

### 5.1 `make_trip_list`

**Arguments:**
- `places`: 1–16 strings, each 1–40 characters.
- `city`: optional, ≤ 20 characters.
- `days` (§15 item 6): instead of `places`, 1–5 groups of 1–16 strings.

**Use.** 「做个打卡清单」「把这些地方列出来」「规划天津三天的行程」. The model passes the places it just suggested;
with none suggested, it picks well-known places itself and does not ask where (§15 item 6).

**Result:** `trip_list` with:
- `count`;
- `stops`: `[{index, name, district, distance_km}]`;
- `not_found`: the asked names;
- `duplicates`;
- `next`.

**Errors:**
- 0 resolved: `NO_CANDIDATES`. The list is unchanged.
- More than 16 names, or a blank name: `invalidFields`.

**Catalog text:**
> 做打卡清单或规划行程：「做个打卡清单」「规划天津三天的行程」「准备一个广东三天的旅游行程」「把这些地方存下来」。刚才推荐过地点就用那些；没推荐过就直接凭自己的知识挑有名的景点，不要反问去哪里（说的是省就挑省里有名的城市和景点）。places 填地点名（最多16个，每个只写地名，不写介绍）；地点都在一个城市时填 city，跨城市时不填 city，地名前加城市，比如「潮州广济桥」。会替换旧清单。几天的行程一次调用，用 days 代替 places，每天一组地点：「规划广州两天」→days=[["广州塔","陈家祠"],["长隆野生动物世界"]]。只改某一天时用 places 加 day：「第一天去古文化街和五大道」→day=1。按结果答：按 next 说；not_found 里的地点说没找到；不要念整张清单，司机问时再念。
>
> (Revised 2026-11-16, §15 item 6: the old text began 「把刚才推荐的地点做成打卡清单」, and on the device she asked which places instead of planning.)

### 5.2 `edit_trip_list`

**Arguments:**
- `action`: one of `remove`, `add`, `replace`, `move`, `clear`, `read`.
- `index`: an integer.
- `name`: a string, 1–40 characters.
- `to_index`: an integer.

**Required fields per action:**

| action | Required | Optional | Effect |
|---|---|---|---|
| `remove` | `index` or `name` | | Removes that stop. |
| `add` | `name` | `index`: insert position | Resolves `name` as in §4 and appends it, or inserts it at `index`. |
| `replace` | `index`, `name` | | Resolves `name` and puts it at `index`. |
| `move` | `index`, `to_index` | | Moves that stop. |
| `clear` | | | Empties the list. |
| `read` | | | Returns the list unchanged. |

- `name` in `remove` matches a stop whose resolved name or asked name contains it after normalize.
- More than one match → `AMBIGUOUS`.

**Result:** `trip_list`, as in §5.1, plus `changed`: `removed|added|replaced|moved|cleared|none`.

**Errors:**

| Code | When |
|---|---|
| `NO_TRIP_LIST` | The list is empty and `action` is not `add` or `clear`. |
| `OUT_OF_RANGE` | `index` or `to_index` is not in 1…n (1…n+1 for `add`). |
| `NOT_FOUND` | `add` or `replace` could not resolve the name. Nothing changes. |
| `TRIP_TOO_LONG` | `add` would make 17 stops. |
| `AMBIGUOUS` | |
| `invalidFields` | A field is missing for the action. |

**Catalog text:**
> 修改打卡清单：「去掉第二个」→remove index=2；「不去古文化街了」→remove name；「加上天津之眼」→add；「第三个换成五大道」→replace；「把瓷房子放到第一个」→move；「清单里有什么」→read；「清空清单」→clear。第几个按她最后说的清单顺序。按结果答：一句话说改了什么和现在几个地点；ok=false 按 error：NO_TRIP_LIST=还没有清单，OUT_OF_RANGE=没有这一项，NOT_FOUND=没找到这个地方，TRIP_TOO_LONG=最多16个地点，AMBIGUOUS=有多个匹配请说第几个。

### 5.3 `route_trip`

**Arguments:**
- `order`: `nearest` (default) or `as_listed`.
- `start`: boolean, default `false`.

**Use.**
- 「串成自驾路线」「规划一下路线」 → `start=false`.
- 「开始导航」 after a trip route → `start=true`.
- 「按清单顺序走」 → `order=as_listed`.

**What it does:**
1. Fewer than 2 stops → `TRIP_TOO_SHORT`, with advice to use `navigate_to` for one place.
2. **Order.**
   - The origin is the same as for `navigate_to` (F-16 / F-15a: the usable fix, or the demo origin in 模拟导航).
   - `nearest`: from the origin, repeatedly go to the closest unvisited stop (great-circle distance, the haversine
     already in `AmapRouteEngine`). The list is reordered to that order.
   - `as_listed`: the list order is kept.
3. **Route.**
   - One `RouteRequest`: `destination` is the last stop, and `waypoints` are the others, in order.
   - With 16 stops that is 15 waypoints, inside 高德's 16.
4. **Recommended route.**
   - The engine returns routes as today. The trip uses the first, recommended path (F-15a §2.5: no route-choice
     step).
   - The route line is drawn on the map as for any route.
5. **Start.**
   - `start=false`: the phase becomes `awaitingRouteSelection`, with this route kept. Nothing starts. The F-15 120 s
     choice lifetime does not apply. The route is kept until the list changes or another destination is asked.
   - `start=true`: guidance starts on the kept route. If the list changed, or there is no kept route, it is
     recalculated first.
   - **No start guard.** F-15a §2.5 withdrew the driver-turn start guard (T-040h): the call is the request, and a
     wrong start is undone with 结束导航. Phase 1 keeps that rule. `start=false` is not a route-choice step. It exists
     because chaining a list into a route is a planning request, not a request to drive (§1, step 4 → step 5).
   - **No trip route while guidance runs** (owner 2026-11-16: "you just abandon this function during navigation"):
     `route_trip` returns `TRIP_WHILE_NAVIGATING` and the running guidance goes on. A `start=true` for the trip
     already being driven is answered as running. The list can still be made and edited.
   - A `navigate_to` drops the kept trip route; the list stays.
6. **Result:** `trip_route` with:
   - `stops`: `[{index, name}]` in route order;
   - `count`, `distance_km` (one decimal), `duration_min`, `tolls_yuan`;
   - `started`;
   - `next`.

**Errors:**

| Code | When |
|---|---|
| `NO_TRIP_LIST` | The list is empty. |
| `TRIP_TOO_SHORT` | Fewer than 2 stops. |
| `ROUTE_CALCULATION_FAILED` | 高德 gives no path within the 10 s route wait. |
| `START_FAILED` | Guidance did not confirm within 8 s (I-1). |
| `AMAP_WEB_KEY_MISSING`, `LIVE_INFO_UNAVAILABLE` | As F-15 §8. |
| `OPTIONS_STALE` | The list changed while the route was being calculated. |

**`next`:**
- Not started: 「说经过几个地点、全程约X公里、大约Y小时Z分钟，问要不要开始导航；不要念每个地点，司机问时再念」.
- Started: 「说已开始导航，第一站是\<name\>，全程约X公里」. In 模拟导航, 「已开始模拟导航」 as in F-15a.

**Catalog text:**
> 把打卡清单串成一条自驾路线（多个途经点）：「串成自驾路线」「规划一下路线」→start=false；看过路线后「开始导航」「出发」→start=true；「按清单顺序走」→order=as_listed，默认 nearest（就近排序，清单会按路线顺序重新编号）。只有一个地点时用 navigate_to。按结果答：按 next 说；不要念每个地点；ok=false 按 error：NO_TRIP_LIST=还没有清单，TRIP_TOO_SHORT=至少要两个地点，ROUTE_CALCULATION_FAILED=路线规划失败，START_FAILED=导航没有启动，不要说已开始，TRIP_WHILE_NAVIGATING=导航中不能串路线。

**开始导航 after a trip route.**
- The model calls `route_trip start=true`. No local intercept is added.
- `choose_navigation_option` while a trip route is kept, and not yet started, is answered `route_unchanged` and
  changes nothing.

## 6. Engine: waypoints

1. **`RouteRequest`** gains `waypoints: [GeoCoordinate]` (GCJ-02, in order; default `[]`).
   - With no waypoints, every existing caller and result is unchanged.
2. **`AmapRouteEngine.fetch`**, with waypoints, adds `waypoints=lng,lat;lng,lat;…` (≤ 6 decimals, `AmapWebClient.lngLat`).
   - Strategy stays 10.
   - More than 16 waypoints is a programming error: the request is not sent and `routeCalculationFailed` is returned.
3. **Stops passed.**
   - A waypoint is passed when the car's position matched on the route (`RouteProgress`, F-15a) goes past the
     polyline point closest to that waypoint. It is also passed when the car comes within 100 m of it.
   - Passed stops are kept in the trip's state and never become unpassed.
4. **Recalculation from here.** `recalculateFromHere` (F-15a §2.5 route change; the 真实导航 off-route reroute, T-040c)
   sends only the waypoints not yet passed, so a reroute never drops or repeats a stop.
5. **Simulation.** 模拟导航 drives the joined polyline, which already runs through every waypoint. Arrival is only at
   the last stop, as today.
6. **Other engines.**
   - `ScriptedNaviEngine` records the waypoints it was given (tests).
   - `AmapNaviEngine` (SDK, T-043) is not in the current build. When it is built, it passes them as the SDK's
     waypoints.

## 7. Record and log

Codes and numbers only (I-8). The place names are already in the conversation record's tool lines.

| Line | When |
|---|---|
| `trip list stops=<n> not_found=<n> duplicates=<n> ms=<ms>` | After `make_trip_list` and after `edit_trip_list`. Edit adds `action=<a> ok=<yes\|no>`. |
| `trip lookup index=<k> ok=no reason=<nomatch\|timeout\|failed>` | Per name not found. |
| `trip route stops=<n> order=<nearest\|as_listed> km=<x> min=<y> started=<yes\|no> ms=<ms>` | After `route_trip`. |
| `trip stop-passed index=<k> of=<n>` | When a stop is passed (§6 item 3). |

## 8. Out of scope in phase 1

- Showing the list, photo cards or numbered pins on screen: phase 2 (§11–§13).
- Saved plans and days (「第一天」): phase 2 (§14–§15). One route is still one day's drive.
- Adding, skipping or reordering stops during guidance (phase 3).
- Per-stop arrival announcements and "next stop" questions (phase 3).
- Ratings: `Place` has no rating, and getting one costs a detail call per stop.

The 2026-11-16 phase 1 text said photo cards were "not planned". Phase 2 replaces that: photos show only when the
phone is not moving (§11 item 4), as the community rules require.

## 9. Acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `make_trip_list` with 8 names; the fake search finds 7, and the 8th's first result has an unrelated name | `trip_list` count 7, indexes 1–7, `not_found` = the 8th; one `trip lookup … reason=nomatch` line | unit |
| 2 | Two names resolve to the same `Place.id` | One stop; the other is in `duplicates` | unit |
| 3 | 17 names; a blank name | `invalidFields`; the list is unchanged | unit |
| 4 | A list of 5: `remove index=2`, then `remove name=古文化街` (one match), then `move index=3 to_index=1` (3 stops are left), then `replace index=9` | Renumbered 1…n after each; the last returns `OUT_OF_RANGE` and changes nothing | unit |
| 5 | `remove name` matching 2 stops; any action except add/clear on an empty list | `AMBIGUOUS`; `NO_TRIP_LIST` | unit |
| 6 | `add` while a slow lookup is running, then `make_trip_list` replaces the list before it ends | The add returns `OPTIONS_STALE`; the new list is unchanged by it | unit |
| 7 | 4 stops, origin and coordinates scripted; `route_trip order=nearest` | The list is reordered to nearest-next; the `RouteRequest` has destination = the last stop and 3 waypoints in that order | unit |
| 8 | Same with `order=as_listed` | Order unchanged; the waypoints are in list order | unit |
| 9 | `AmapRouteEngine` with 3 waypoints (fake transport) | The URL has `waypoints=lng,lat;lng,lat;lng,lat` at ≤ 6 decimals; with none, the URL is byte-identical to today | unit |
| 10 | `route_trip start=false`, then `route_trip start=true` twice within 5 s | Nothing starts after the first call; the route line is drawn; then exactly one navigation starts, on the kept route with no new calculation | unit |
| 11 | A route is kept: `edit_trip_list remove`, then `route_trip start=true`; a second keep, then `navigate_to` | The start recalculates without the removed stop; `navigate_to` drops the kept route and the list is unchanged | unit |
| 12 | Navigating a 4-stop trip; the scripted progress passes stops 1–2, then off-route recalculation | The recalculation request has stop 3 as its only waypoint and stop 4 as destination; `trip stop-passed` lines for 1 and 2 | unit |
| 13 | `route_trip` with 1 stop; engine fails; no confirm within 8 s | `TRIP_TOO_SHORT`; `ROUTE_CALCULATION_FAILED`; `START_FAILED`, and the reply never claims a start (I-1) | unit |
| 14 | Existing F-15 / F-15a / F-16 suites | Unchanged | unit |
| 15 | Device, 模拟导航: 「推荐天津一日游的几个景点」, 「做个打卡清单」, 「去掉第二个」, 「串成自驾路线」, 「开始导航」 | She says the count, then the change, then the stops, km and time; guidance starts; the map line runs through every stop; the record has the `trip` lines | D |

## 10. Tasks

| Task | Scope | Verify |
|---|---|---|
| T-040i | Phase 1: `TripList` and name resolving (§3–4), the three tools in the catalog with validation (§5), `RouteRequest.waypoints` and `AmapRouteEngine` (§6 items 1–2), stops passed and recalculation (§6 items 3–4), record lines (§7); rows 1–15 | unit, build, D |
| T-040j | Phase 2a: poster cards and the moving strip (§11), place photos (§12), editing on screen (§13), numbered pins and 途经1…N on the map (§13 item 5), the tap note (§13 item 4); rows 16–25 | unit, build, D |
| T-040l | Phase 2b: the trip saved on the phone (§14), named plans and days (§15), the `trip_plans` tool (§16), record lines (§17); rows 26–35 | unit, build, D |
| T-040k | Withdrawn 2026-11-17: replaced by T-040n (§25–§34, one stop at a time) | — |

Trace ids: T-040i, T-040j and T-040l are each added to `specs/trace-ids.txt` (F-15b) with their tests, not before, so
spec-trace stays green.

---

# Phase 2: cards, screen editing, saved plans (T-040j, T-040l)

## 11. Poster cards and the moving strip (T-040j)

**Why.** The video shows the list as cards over the map, and the owner asked for "poster like stuff you can observe on
the screen" (2026-11-16).

**Sources (read 2026-11-16).**
- Google's car app rules: no images on screen while driving, except images that help the driving task (rule IU-1);
  text cut to 2 lines while driving; tasks of about 5 screens, longer ones paused until parked
  ([Android car app quality](https://developer.android.com/docs/quality-guidelines/car-app-quality)).
- NHTSA's visual-manual guidelines: each glance away from the road at most 2 s, a whole task at most 12 s
  ([NHTSA 811781](https://www.nhtsa.gov/sites/nhtsa.gov/files/811781.pdf)).
- Google Ask Maps builds a day-by-day trip with stop details and saves it as a list
  ([Google blog](https://blog.google/products-and-platforms/products/maps/ask-maps-immersive-navigation/)).

1. **Where.** On the 导航 tab, a row of cards over the bottom of the map whenever the trip list has stops. Empty list:
   no row.
2. **One card.**
   - The stop's number (1…n), large.
   - The place photo (§12), or a placeholder: the first character of the name on a plain colour.
   - The name (one line), district, and distance from the origin in km (one decimal).
   - A ✕ button (§13).
   - Passed stops (§6 item 3) are greyed and marked 已到.
3. **Order.** Cards follow the list's indexes. After `route_trip order=nearest` they follow the new order.
4. **Moving rule.**
   - The phone is **moving** when its own speed (F-16b `speedMetersPerSecond`) is at least 8 km/h, or 真实导航 is
     running. It stops being moving after 3 s below 3 km/h.
   - 模拟导航 alone is not moving: the phone is not.
   - Speed unknown counts as moving while 真实导航 runs, and as not moving otherwise.
   - **While moving**, the card row becomes the **strip**: one line, 「1 古文化街 · 2 五大道 · 3 天津之眼 …」, at most
     2 lines, no photos, no ✕, no dragging, no buttons. Taps on the strip do nothing.
   - Voice works the same moving or not.
5. **Buttons (not moving).**
   - 「串成路线」 → `route_trip start=false` (§13 item 1).
   - 「开始导航」, shown once a trip route is kept → `route_trip start=true`.
   - Day tabs 「第1天」「第2天」… when the plan has more than one day (§15).
   - 「我的行程」 opens the saved plans sheet (§16 item 6).
6. **Card details (not moving).** A tap on a card opens a sheet with the photo, address, opening hours and phone from
   the place detail (the same fields as F-18 place_details). Nothing is spoken. (§21 adds an introduction of the spot
   and fixes the tap.)

## 12. Place photos (T-040j)

1. **Source.** 高德 `/v3/place/detail` with `extensions=all` (`AmapWebClient.detail` already sends it) returns
   `photos`: a list of `{title, url}` ([高德 搜索POI](https://lbs.amap.com/api/webservice/guide/api-advanced/search)).
   `Place` gains `photoURL: URL?`: the first `photos[].url`, nil when there is none. Older docs spell the subfield
   `titile`; only `url` is read.
2. **When.**
   - After a stop is resolved (§4), one detail call per stop, at most 4 at once.
   - It runs after the tool result is returned, so it never delays her reply.
   - A stop that already has `photoURL` (a saved plan, §14) makes no call.
3. **Secure links only.** An `http://` link is tried once as `https://`. No App Transport Security exception is added.
   If the secure link fails, the card shows the placeholder.
4. **Size and cache.**
   - Images are downsampled to twice the card's size before they are kept.
   - Memory cache: 32 images. Disk cache: `Caches/TripPhotos`, at most 20 MB, oldest removed first.
   - Saved plans keep the link, not the image.
5. **Failure.** No photo, a failed call or a quota error shows the placeholder. The list is never changed by a photo
   failure. A failed photo is tried again at most once per app launch.
6. **Cost.** One extra 高德 call per stop: at most 16 for a full list.

## 13. Editing on screen, pins on the map (T-040j)

1. **Same path as voice (I-6).** Every tap is a `UIIntent` that becomes the tool call the voice path makes, through
   the same dispatcher and executor, as `UIIntent.choose` does today. New intents:

   | Intent | Tool call | When |
   |---|---|---|
   | `tripRemove(index)` | `edit_trip_list action=remove index` | Not moving |
   | `tripMove(from, to)` | `edit_trip_list action=move index to_index` | Not moving |
   | `tripRoute(start: Bool)` | `route_trip start` | Not moving |
   | `tripDay(day)` | `edit_trip_list action=read day` | Not moving |
   | `tripAdd(row)` | Adds row `row` of an open destination list (below) | Not moving |
   | `tripOpenPlan(name)` | `trip_plans action=open name` | Not moving |

   The executor refuses a tap intent while moving with `NOT_WHILE_MOVING` (no change). The screen does not offer them
   then, so this is the backstop.
2. **Drag to reorder.** Long-press and drag a card; dropping it is one `tripMove`. Not moving only.
3. **Add from a list.** When a destination list from `navigate_to` is open and the trip list exists, each row has
   「加入清单」. It adds that already-found `Place` with no new lookup, as `add` at the end. A full list returns
   `TRIP_TOO_LONG`.
4. **Tap note.** After a tap's tool result, when a voice session is connected, a silent note in the F-18 §21 form is
   sent so she knows the list changed:
   > [系统] 司机在屏幕上<去掉了第k个：名字|把第k个移到了第m个|加入了名字|串成了路线|开始了导航|打开了行程「名字」>，现在清单有n个地点。这句不用回答。

   No session: no note. The list is the app's, and she reads it with `edit_trip_list read` when asked.
5. **Map pins and labels.**
   - Numbered pins 1…n at the stops' coordinates whenever the list has stops, before and after routing.
   - On a kept or running trip route, the stops are labelled 途经1…途经n−1 and 终点, as in the video.
   - Passed stops are greyed.
   - `RouteGeometry` gains `stops: [TripPin]` (index, coordinate, label, passed); the map draws them.

## 14. The trip saved on the phone (T-040l)

1. **Current plan.** The current plan (§15: its name, days and stops) is written to
   `Application Support/trip/current.json` after every change, with an atomic write, and read at launch. It replaces
   phase 1's "an app restart empties it" (§3 item 2).
2. **What is kept per stop:** asked name, `Place` id, name, address, district, coordinate (GCJ-02), `photoURL`.
   Not kept: generations, passed stops, the kept route. A restored plan is recalculated by `route_trip`.
3. **Privacy (I-8).**
   - Place names never go to the log or the conversation record's numbers lines.
   - The files have complete-until-first-unlock protection and are excluded from backup.
4. **Bad file.** An unreadable file, or an unknown `version`, starts empty and logs `trip load ok=no`. The file is
   moved aside as `current.bad.json`, not deleted.

## 15. Named plans and days (T-040l)

**Why.** The video starts with 「规划天津三天的行程」 and a day-by-day plan. Ask Maps keeps a day-by-day trip as a saved
list (§11 sources).

1. **A plan** has:
   - an optional name, 1–20 characters;
   - 1–5 days, each a `TripList` of 1–16 stops (§3);
   - a current day: the last day made, edited, read or routed.
2. **Days in the tools.** `make_trip_list`, `edit_trip_list` and `route_trip` gain an optional `day` (1–5):
   - `make_trip_list` with `day` replaces only that day and keeps the others. `day` may be at most the number of days
     + 1. Without `day`, it replaces the whole plan with one day, as in phase 1.
   - `edit_trip_list` and `route_trip` with `day` act on that day; without it, on the current day.
   - `edit_trip_list action=clear` with `day` removes that day; the later days move up one. Without `day`, the whole
     plan is cleared.
   - A day out of range returns `OUT_OF_RANGE`.
3. **Results.** `trip_list` and `trip_route` add `day` and `days` (the count).
4. **One route is one day.** Routing a day never adds stops of another day.
5. **Catalog text additions** (appended to each tool's §5 text):
   - `make_trip_list`: 「多天的行程按天分别调用，day 填第几天：「第一天去古文化街和五大道」→day=1。」
   - `edit_trip_list`: 「说到第几天时填 day，不说就是刚才那一天。」
   - `route_trip`: 「「开始第二天的导航」→day=2, start=true。」
   (Item 7 replaces the `make_trip_list` addition above; the edit and route additions stay.)
6. **A whole plan in one call** (device 2026-11-16, eeb8763). 「帮我做一个天津打卡清单」 and 「准备一个三天的广东旅游行程」
   both got a question back (「您想把哪些地方加入…」「广东很大，您想去哪些城市」), because the text said to list the places
   just recommended. And three per-day calls arrive together and run at once, so all but one would end
   `OPTIONS_STALE` (§4: a change while lookups run). So:
   - `make_trip_list` takes `days` instead of `places`: 1–5 groups of 1–16 names. It replaces the whole plan
     (name cleared); the first day with stops is current. A place twice anywhere in the plan is a duplicate. A day where nothing was
     found stays as an empty day. All found nothing: `NO_CANDIDATES`. `days` with `places` or with `day`, more than
     5 groups, or an empty group: `invalidFields`.
   - `next` says the day count and each day's count, and asks for one or two main places a day. The result also has
     `plan`: each day's stop names. The `trip list stops=` record line counts the whole plan here.
   - The text (§5.1) says: with nothing recommended, pick well-known places herself without asking; for a
     province, its well-known cities; across cities no `city`, the city in front of the name (「潮州广济桥」).

## 16. Saved plans: the `trip_plans` tool (T-040l)

1. **Arguments:**
   - `action`: `save`, `open`, `list`, `delete`, `rename`;
   - `name`: 1–20 characters;
   - `new_name`: 1–20 characters, for `rename`.
2. **Actions:**

   | action | Required | Effect |
   |---|---|---|
   | `save` | `name` | Saves the current plan under `name` and gives the current plan that name. Same name: replaced, `replaced: true`. |
   | `open` | `name` | Makes that plan the current plan (a copy). |
   | `list` | | Names with days and stop counts, newest first. |
   | `delete` | `name` | Deletes the saved plan. The current plan is not changed. |
   | `rename` | `name`, `new_name` | Renames the saved plan (and the current plan if it has that name). |

3. **Nothing is lost on open.** If the current plan has stops and no name, opening another plan keeps it as
   「上一个清单」 (one slot, replaced each time). She says so once.
4. **Name matching.** Exact after `TranscriptText.normalize`. Otherwise one saved name containing it, or contained in
   it. Several → `AMBIGUOUS`. None → `PLAN_NOT_FOUND`.
5. **Limits and errors.**

   | Code | When |
   |---|---|
   | `NO_TRIP_LIST` | `save` with an empty current plan. |
   | `PLAN_NOT_FOUND` | `open`, `delete` or `rename` found no plan. |
   | `PLANS_FULL` | `save` of a new name with 20 plans saved. |
   | `AMBIGUOUS` | More than one name matches. |
   | `invalidFields` | A field is missing or too long for the action. |

6. **Screen.** 「我的行程」 (not moving) lists the saved plans with name, days and stop count. A tap opens one
   (`tripOpenPlan`). A swipe deletes one after a confirm on screen.
7. **Opening while navigating.** The plan is replaced and a kept trip route is dropped. Guidance on the running route
   goes on until 结束导航 or a new `route_trip start=true` (F-15a §9, one trip at a time).
8. **Saved in** `Application Support/trip/plans.json`, the same way as §14.
9. **Catalog text:**
   > 保存、打开、列出、删除、改名行程：「把这个行程存成天津一日游」→save name=天津一日游；「打开天津一日游」→open；「我存了哪些行程」→list；「删掉天津那个行程」→delete；「改名叫周末出游」→rename。打开后要导航就再调用 route_trip。按结果答：一句话说做了什么；list 只说有几个和名字；ok=false 按 error：NO_TRIP_LIST=还没有清单，PLAN_NOT_FOUND=没有这个行程，PLANS_FULL=最多存20个，AMBIGUOUS=有多个请说全名。

## 17. Phase 2 record and log

Codes and numbers only (I-8).

| Line | When |
|---|---|
| `trip photo ok=<n> none=<n> failed=<n> ms=<ms>` | After the photos of one change are done. |
| `trip strip moving=<yes\|no>` | When the card row turns into the strip or back. |
| `trip tap action=<remove\|move\|route\|start\|add\|day\|open> ok=<yes\|no>` | After a tap's tool result. |
| `trip plan action=<save\|open\|list\|delete\|rename> ok=<yes\|no> days=<n> stops=<n>` | After `trip_plans`. |
| `trip load ok=<yes\|no> days=<n> stops=<n>` | At launch. |

New error codes (`ToolErrorCode`): `NO_TRIP_LIST`, `TRIP_TOO_LONG`, `TRIP_TOO_SHORT`, `NOT_FOUND` (phase 1);
`PLAN_NOT_FOUND`, `PLANS_FULL`, `NOT_WHILE_MOVING` (phase 2). Each gets a `ToolFailureAdvice` sentence.

## 18. Phase 2 out of scope

- Ratings, prices and reviews on cards.
- Sharing a plan to another phone, iCloud sync.
- Hour-by-hour schedules, hotels and tickets.
- Video or animated cards.
- Planning while moving by screen: voice only.

## 19. Phase 2 acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 16 | A list of 5, not moving | 5 cards in index order with number, name, district, km and ✕; an empty list shows no row | unit (view model) |
| 17 | Speed 10 km/h; then 2 km/h for 3 s | The strip (names and numbers, no photos, no ✕, no buttons), `trip strip moving=yes`; then cards again, `moving=no` | unit |
| 18 | 模拟导航 with the phone still; 真实导航 with speed unknown | Cards; strip | unit |
| 19 | Detail returns 2 photos with an `http://` first link; another stop has none; a third fails | The first gets the `https://` form; the others get the placeholder; `trip photo ok=1 none=1 failed=1`; the list is unchanged | unit |
| 20 | A saved stop with `photoURL` | No detail call | unit |
| 21 | Tap ✕ on card 2, not moving | Exactly one `edit_trip_list remove index=2` through the dispatcher; the list renumbers; one tap note with the new count; `trip tap action=remove ok=yes` | unit |
| 22 | `tripRemove` while moving | `NOT_WHILE_MOVING`, nothing changes, no note | unit |
| 23 | Drag card 4 to place 1 | One `move index=4 to_index=1` | unit |
| 24 | A destination list is open and a list of 16 exists; 「加入清单」 | `TRIP_TOO_LONG`, nothing changes; with 15, the place is added with no new lookup | unit |
| 25 | A 4-stop list; then a kept trip route; then stop 1 passed | Pins 1–4; labels 途经1–3 and 终点; pin 1 greyed | unit (geometry) |
| 26 | Change the list, restart the controller from the file | The same plan, days and stops come back; no lookups; no passed stops; no kept route | unit |
| 27 | An unreadable `current.json` | Empty plan, `trip load ok=no`, the file moved to `current.bad.json` | unit |
| 28 | The log and record after a full session | No place names in log or numbers lines | unit |
| 29 | `make_trip_list day=1`, then `day=2`, then `day=4` | 2 days kept; the third returns `OUT_OF_RANGE` | unit |
| 30 | `route_trip day=2 start=true` | The route has only day 2's stops; the current day becomes 2 | unit |
| 31 | `edit_trip_list clear day=1` on 3 days | 2 days left; the old day 2 is now day 1 | unit |
| 32 | `trip_plans save 天津一日游`, `list`, `open 天津`, `rename`, `delete` | Each as §16; `open 天津` finds the one plan by containment | unit |
| 33 | An unnamed current plan, then `open` another | The old one is kept as 「上一个清单」 | unit |
| 34 | 20 saved, `save` a new name; two names contain the asked one | `PLANS_FULL`; `AMBIGUOUS` | unit |
| 35 | Device, 模拟导航, parked: 「规划天津两天的行程」, 「做个打卡清单」 (two days), cards with photos, ✕ one card, 「存成天津周末」, close and reopen the app, 「打开天津周末」, 「开始第一天的导航」 | She makes two days; the cards show photos or placeholders; the ✕ removes the stop and she knows it; after reopening the plan is there; guidance runs through day 1's stops with 途经 labels; the record has the `trip` lines | D |
| 36 | One `make_trip_list days=[[古文化街,五大道],[天津之眼,古文化街],[瓷房子,盘山]]` over a 4-day plan | 3 days, day 1 current, name cleared; 古文化街 a duplicate, 盘山 not found; `next` says 第1天2个，第2天1个，第3天1个 | unit |
| 40 | Picker (fake): 北京故宫 with [北院区(建设中), 故宫博物院] answered 2; 陈家祠 with [地铁站, 陈家祠堂] answered 2; 路环那家葡挞 answered 0 | 故宫博物院 and 陈家祠堂 listed; 路环那家葡挞 in `not_found`; one picker call for the whole list; no `check` field | unit |
| 41 | The first 2 searches refused `quota` | All 3 found after retries; 2 lookups at once | unit |
| 42 | Every search refused `quota` | `NO_CANDIDATES`; `trip lookup index=1 ok=no reason=busy` | unit |
| 43 | The same names again with 高德 refusing everything | Found from the cache; no new search | unit |
| 44 | Device: 「帮我准备一个澳门两天游」, then 「加上路环的安德鲁」 | Every stop found; 安德鲁饼店 added | D |
| 45 | Picker fails, has no key, or answers after 2.5 s (manual clock) | Every name takes 高德's first result; `trip pick ... ok=no` | unit |
| 46 | A name with one result, and a cached name | No picker call for them | unit |
| 47 | `QwenPlacePicker` request and parse (fake send) | Body: `qwen3.7-flash`, `enable_search=false`, the copied EntGPT prompt with the candidates; answer lines parsed, `0` → none, unreadable → error | unit |
| 48 | `make_trip_list` and `edit_trip_list` declarations and responses | `NON_BLOCKING`; responses carry `WHEN_IDLE` | unit |
| 49 | `route_trip` called while `make_trip_list` still waits on its lookups | The route runs after the list is made, on the new list; the list is not `OPTIONS_STALE` | unit |
| 50 | Device: 「规划北京一日游，去故宫和陈家祠…」 style request, then 「串成路线」 | She says one line, keeps talking, explains the list when quiet; 故宫博物院 listed; the route uses the finished list | D |
| 51 | `edit_trip_list add` called while `make_trip_list` still waits on its lookups | The edit runs after the list is made and adds to it; neither is `OPTIONS_STALE` | unit |
| 52 | The picker fails for a name, then the same name is listed again | The second list asks the picker again (the fallback was not cached) | unit |
| 36b | `days=[[盘山],[五大道]]`, then `days=[[盘山],[盘山]]` | Day 1 stays empty and day 2 is current; nothing found is `NO_CANDIDATES`, plan unchanged | unit |
| 37 | `days` with `places`, `days` with `day`, 6 groups, an empty group, no field | `invalidFields` | unit |
| 38 | The `make_trip_list` text | Says to pick places herself and not ask, and `days` for several days | unit |
| 39 | Device: 「帮我准备一个三天的广东旅游行程」 with nothing said before | One `make_trip_list days=…` call, no question; 3 day tabs | D |

## 20. Implementation notes (T-040i, T-040j)

1. **Code.**
   - `TripList`, `TripOrder` and `TripStopTracker` are in `NovaNav/Trip/TripList.swift`.
   - `TripPlanner` (the three tools, taps, photos) is in `TripPlanner.swift`.
   - `TripMoving`, `TripScreen`, `TripPin`, `TripPhotoLink` and `TripPhotoCachePolicy` are in `TripScreen.swift`.
   - The trip route is `NavigationController.routeTrip`.
   - The engine waypoints and stops passed are in `AmapRouteEngine`.
   - The app's cards, strip, pins, photo store and details sheet are in `App/NovaDrive/TripCardsView.swift` and `DriveView`.
2. **Kept route (§5.3 item 5).** Every list change except `route_trip`'s own reorder drops a kept, not yet started
   trip route, and takes its line off the map. `route_trip start=true` with no `order` keeps the kept route's order,
   so 「按清单顺序走」 then 「开始导航」 starts the route she described.
3. **A change while starting.** A list change while a start is in flight stops that guidance and returns
   `OPTIONS_STALE`, so a start never runs on a list she no longer has.
4. **Cancelled calls.** A `make_trip_list`, `add` or `replace` cancelled mid-lookup (barge-in) changes nothing and
   returns `OPTIONS_STALE`.
5. **Stops passed (§6 item 3).** Each stop's closest route point is searched from the previous stop's point onward,
   so a stop near an earlier leg (out and back, a route that crosses itself) is not passed early.
6. **Taps (§13 item 1).** A card tap calls `TripPlanner.tap`. It runs the same `ToolCatalog.validate` and the same
   executor as the voice call, not `AgentCore`'s `.ui` path. Taps do not make her speak: §13 item 4 sends a silent
   note, `AgentEvent.screenNote`, which joins the F-18 §21 note flush.
7. **Pins (§13 item 5).** Pins come from `TripPin.pins(list, routed:, passed:)` in the view, not from
   `RouteGeometry.stops`. The engine knows coordinates, not names or labels.
8. **Persona.** `edit_trip_list` is not repeat-sensitive: 「去掉第一个和第二个」 can be two identical `remove index=1`
   calls. The persona base is unchanged: the trip tools are 要去的地方 and 导航 in its strict scope.
9. **No trip route during guidance** (owner 2026-11-16). `route_trip` while guidance runs is `TRIP_WHILE_NAVIGATING`;
   the guidance is never stopped for it, and 「串成路线」 is not shown then.
10. **Phase 2b (T-040l).**
    - **Plan.** `TripPlan` (days, current day, name) and the `SavedTripPlans` codec are in `NovaNav/Trip/TripPlan.swift`.
      The planner's list is the plan's current day. A plan-wide `revision`, not one day's list generation, tells a
      kept trip route or a slow lookup that the plan moved on.
    - **Files.** `AppTripFiles` (app) writes `current.json` and `plans.json` atomically, with
      complete-until-first-unlock protection, and excludes the folder from backup.
    - **Loading.** The drive screen prepares the trip at appear (`prepareTrip`), so a restored plan's cards show before
      any voice session.
    - **Kept in a saved stop.** The distance from the origin is not kept (§14 item 2 does not list it): restored cards
      show no km until the stop is looked up again.
    - **Taps.** A day tab is `edit_trip_list action=read day` and sends no note (the list did not change). 「我的行程」
      also deletes by swipe, confirmed on screen, through `trip_plans delete` (a `TripTap.deletePlan`, line
      `trip tap action=delete`), so that tap goes through the executor too (I-6).
    - **`trip_plans`.**
      - A `rename` onto another saved plan's name is refused with `invalidFields` and changes nothing.
      - `open name=上一个清单` opens the §16 item 3 slot.
      - Plans are listed newest saved first; saving an existing name again moves it to the front.
11. **During guidance the plan stays saved** (owner 2026-11-16: "a saved navigation state and later able to call
    locally"). The plan is written to `current.json` after every change, guidance or not. Named plans and
    「上一个清单」 open later from the phone's files, with no 高德 lookups (`trip_plans open`, 「我的行程」); a route
    is calculated again only on `route_trip` after guidance ends.
12. **Build handoff** (owner 2026-11-16): the app build (Codemagic), the device rows 15 and 35 and the on-screen
    checks of phase 2 go to the owner's local agent. This session does not build or install.
13. **Reconnect after a lost socket** (device 2026-11-16, eeb8763; F-24 recovery, not a trip change). After a ping
    loss every resumed setup was closed 1008 「BidiGenerateContent session is already connected to an existing client」
    until the driver gave up, so nothing she heard got an answer. `GeminiCloseClassifier` now maps that close on a
    resumed setup to `RESUME_UNAVAILABLE`, like 「session not found」: the handle is dropped and the next attempt is
    a fresh session.

---

# Phase 2c: device fixes 2026-11-17 (T-040m)

Device run ecd94e6 (ipa142, record 20261117-163436). The owner listed three problems; this phase covers the first two.

## 21. Spot introduction on the card details

**Why.** 「点卡片应该显示景点信息」. Two faults:
- A tap on a card opened nothing. The record has no detail line, while ✕ and day taps worked. The card used
  `.onTapGesture` next to `.draggable` inside a horizontal `ScrollView`.
- Even when it opens, the sheet shows only 高德's listing: photo, address, hours, phone. A tourist wants to know what
  the place is and why to go. 高德 has no such text.

1. **The tap.** The card is a plain `Button` that opens the sheet. Long-press drag (§13 item 2) and ✕ stay as they
   are. Not moving only, as before.
2. **What the sheet shows, top to bottom:**
   - photo and 「n 名字」, as now;
   - 「介绍」: the introduction (item 3);
   - address, opening hours, phone from 高德, as now.
3. **Where the introduction comes from.** One call to the existing `WebSearchService` (Qwen, F-18 §16) with the
   query 「介绍一下<城市><名字>」. `<城市>` is the stop's `city`, left out when unknown or already at the start of the
   name. The answer text is shown as it comes back. The search system text is not changed and no new prompt is
   written (owner rule 2026-11-05): only the query is new.
4. **While waiting and on failure.**
   - Waiting: 「正在查介绍…」 under the name; the 高德 lines show as soon as they arrive.
   - Failure, timeout, no key, or an empty answer: 「没有查到介绍」. The 高德 lines still show.
   - A saved 家/公司 stop (`saved_` id): no search, no 「介绍」 section.
5. **Only once.** An answer is kept in memory per place id for the app's life. Opening the same card again makes no
   new search. A failure is not kept, so the next open tries again.
6. **Nothing is spoken**, as before. The sheet is closed by swiping down.
7. **Privacy (I-8).** The place name goes to Qwen in the query, as `web_search` already sends what she searches. The
   log gets codes only: `trip intro ok=<yes|no|cached> ms=<ms>`.
8. **Code.** The search is made by `AgentRuntime.openTripDetail` next to the 高德 detail call, both started at once;
   the sheet is `TripDetailSheet` in `TripCardsView.swift`.

## 22. 「把页面关掉」 puts the trip cards away

**Why.** At 295219 「你先把这个页面给我关掉吧」 called `exit_navigation_mode`. It cancelled the route just made, but the
cards, day tabs, 「串成路线」 and pins stayed: nothing could hide them except clearing the plan. At 308839
「我是说你这个导航这个页面关掉」 she called nothing and said 「已经退出导航模式，页面已关闭」, which was false.

1. **Hidden means:** no card row or strip, no day tabs, no 「串成路线」「开始导航」「我的行程」 buttons, no trip pins. One
   small 「行程」 button stays at the bottom of the map. The plan is not changed: `current.json` and saved plans stay.
2. **What `exit_navigation_mode` does, by state:**

   | State | Effect | status |
   |---|---|---|
   | Guidance running | Stops guidance, as now. The cards stay. | `navigation_stopped` |
   | A list or route choice is open | Cancels it, as now, and hides the cards when the plan has stops. | `navigation_selection_cancelled` |
   | Nothing open, cards shown | Hides the cards. | `trip_cards_hidden` |
   | Nothing open, cards already hidden, or no plan | Nothing changes. | `no_navigation_active` |

   `next` for `trip_cards_hidden`: 「只说一句：行程卡片先收起来了，行程还在，说「打开行程」就再拿出来。」
3. **Shown again by:**
   - a tap on 「行程」 (the §13 day tap of the current day: `edit_trip_list action=read`);
   - any trip tool call: `make_trip_list`, `edit_trip_list` (read included), `route_trip`, `trip_plans open`;
   - an app restart (hidden is not saved).
4. **Catalog text.**
   - `exit_navigation_mode`: 「按 status 答：」 is replaced with
     「「把页面关掉」「关掉这个页面」「收起来」也调用它：没有导航时收起行程卡片，行程还在。每次说关掉都要调用，没调用不要说已关闭。按 status 答：trip_cards_hidden=已收起行程卡片，」.
     This is an iOS change to an Android-generated text, made with a checked replace as `searchOnLiveInfo` does (F-09).
   - `edit_trip_list`: 「「清单里有什么」→read」 becomes 「「清单里有什么」「打开行程」「看看行程」→read」.
5. **She must not claim it without the call.** The text above tells her to call it every time. When nothing is open,
   the result is `no_navigation_active` and she says so truthfully.
6. **Log:** `trip cards hidden=<yes|no>` when the cards are put away or shown again.

## 23. Phase 2c acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 54 | Card tap on 陈家祠 (city 广州) with a fake search answering 「陈家祠是…」 | The sheet shows the answer under 「介绍」 and the 高德 lines; the query was 「介绍一下广州陈家祠」 (fixed 2026-11-17: the first example, 广州塔, starts with its city, so item 3 gives 「介绍一下广州塔」) | unit |
| 55 | The search fails; then the card is opened again and it answers | 「没有查到介绍」 with the 高德 lines; the second open searches again and shows the answer; a third open makes no search, `trip intro ok=cached` | unit |
| 56 | A saved 家 stop | No search; no 「介绍」 section | unit |
| 57 | A stop named 「珠海环宇城」 with city 珠海 | Query 「介绍一下珠海环宇城」 (city not doubled) | unit |
| 58 | Device, parked: tap three cards | Each opens the sheet with an introduction that says what the place is; drag and ✕ still work | D |
| 59 | A plan with stops, nothing open: `exit_navigation_mode` | `trip_cards_hidden`; the snapshot says hidden; the plan unchanged; a second call gives `no_navigation_active` | unit |
| 60 | A route choice open over a plan: `exit_navigation_mode` | `navigation_selection_cancelled` and the cards hidden | unit |
| 61 | Cards hidden; then `edit_trip_list read`; hidden again, then `route_trip` | Shown after each call; `trip cards hidden=no` | unit |
| 62 | Guidance running: `exit_navigation_mode` | `navigation_stopped`; cards not hidden | unit |
| 63 | The `exit_navigation_mode` and `edit_trip_list` texts | Contain the §22 item 4 sentences; the rest of the Android text is unchanged | unit |
| 64 | Device: plan on screen, 「把页面关掉」, then 「关掉」 again, then 「打开行程」 | Cards, tabs, buttons and pins go, the 「行程」 button stays; the second time she calls the tool and says it is already closed or that there is no navigation; 「打开行程」 brings them back | D |

## 24. Phase 2c tasks

| Task | Scope | Status |
|---|---|---|
| T-040m | §21 and §22, rows 54–64 | Built 2026-11-17 (`TripIntro`, `TripPlanner.cardsHidden`, `exit_navigation_mode` hides the cards); rows 58, 64 device |

---

# Phase 3: the plan ordered by location, one stop at a time (T-040n)

Owner decision 2026-11-17: "the multi point routing is actually a nonsense function, you only need to make the travel
plan based on the location, then later you can just based on the plan to call next destination". This phase replaces
the 途经点 trip route (§5.3, §6, §13 route taps) and T-040k.

## 25. Why

Device run 7fdcdd6 (records 20261117-174009 and -174419):
- 「你应该把珠海那个行程放到第一天，然后重新排一下」 → `make_trip_list {}` → `INVALID_FIELDS`, then 「我无法重新安排行程，请告诉我完整的地点名单」.
  - She did not know the plan's places: `trip_plans open` returns only counts.
  - No tool moves a day or a stop to another day, or starts from a chosen stop.
- `route_trip start=true` drove 长隆(横琴) → 环宇城 → 渔女, 45.1 km, 97 min: backwards from 香洲.
  - `order=nearest` is straight-line distance one stop at a time ([TripList.swift](../../Packages/NovaCore/Sources/NovaNav/Trip/TripList.swift) `TripOrder`), never driving time.
  - The order matches what the code does with no position (start at stop 1). The record has no line saying which start was used.
  - 高德 drives the 途经点 in the order sent and never reorders them.

**Sources (read 2026-11-17).**
- Self-drive practice: group nearby places into one day each, then order them
  ([V2EX](https://www.v2ex.com/t/1013580), [知乎](https://www.zhihu.com/question/29689371)); 途经点 mostly steer which
  highway is taken ([V2EX](https://www.v2ex.com/t/1013580), [少数派](https://sspai.com/post/88227)).
- Navigation apps go one leg at a time: Apple Maps treats each stop as the next destination with a 「Next」 control
  ([Gadget Hacks](https://ios.gadgethacks.com/how-to/your-complete-guide-planning-multi-stop-trips-apple-maps-your-iphone-0385152/));
  a route is one leg per stop ([afi.io](https://blog.afi.io/blog/plan-a-route-with-multiple-stops-using-the-routes-api/)).
- Multi-stop routes drop stops after a detour
  ([MyRoute forum](https://forum.myrouteapp.com/topic/6782/issues-system-automatically-skipping-waypoints-and-therefore-changing-the-whole-route?page=1),
  [mapbox-navigation-ios #4509](https://github.com/mapbox/mapbox-navigation-ios/issues/4509)).
- Ordering by travel time is what Google's waypoint optimization does
  ([Google Routes](https://developers.google.com/maps/documentation/routes/opt-way)); nearest-neighbour then 2-opt is
  the usual small-tour method ([2-opt](https://jmsallan.netlify.app/blog/2-opt-local-search-for-the-tsp)).
- Multi-day: group places into days, then order each day, balancing the days
  ([journai](https://pypi.org/project/journai-lib), [Springer](https://link.springer.com/chapter/10.1007/978-3-030-94751-4_17),
  [dev.to](https://dev.to/jinglescode/holiday-itinerary-with-machine-learning-2gbo)).
- 高德 distance: `/v3/distance`, `type=1` driving, many `origins` separated by `|` to one `destination`; it returns
  `distance` (m) and `duration` (s) per origin ([高德 距离测量](https://lbs.amap.com/api/webservice/guide/api/direction#distance),
  [apifox copy](https://apifox.com/apidoc/docs-site/759159)).

## 26. Driving times

1. **Table.** For a start S and stops P1…Pn of the plan, the driving time between every pair is read from 高德
   `/v3/distance type=1`: one request per stop as `destination`, with S and all other stops as `origins`. n stops make
   n requests (16 at most). The time from a stop back to S is not needed.
2. **Cache.** A pair's time is kept for 30 minutes in memory (keyed by the two place ids, or `here` rounded to
   ~100 m). A reorganize within that time makes no new request.
3. **At most 4 requests at once**; a `quota` refusal is retried as §4's lookups are.
4. **Failure.** Any pair missing after retries: nothing is reordered, the plan is unchanged, and the result is
   `ROUTE_TIMES_UNAVAILABLE`. Straight-line distance is never used to order a plan.
5. **Code.** `AmapWebClient.drivingTimes(origins:destination:)` (NovaServices) behind a NovaPorts protocol
   `DrivingTimes`; the table and ordering are pure NovaCore.

## 27. Ordering (pure, `TripOptimizer`)

1. **One day.** An open path from the start through every stop of the day, with the smallest total driving time.
   - 8 stops or fewer: every order is tried (8! = 40,320).
   - More: nearest neighbour by driving time, then 2-opt until no swap shortens it.
   - Equal totals keep the current order.
2. **Named start.** When the driver names a stop to start from, that stop is fixed first and the path starts there
   (the time from the car to it is not counted).
3. **Days.** All stops of the plan are put on one path as in item 1, then cut into D consecutive days.
   - D is the asked number of days, else the plan's current number of days.
   - The cut keeps each day at least 1 stop and makes the longest day as short as possible. A day counts its driving
     minutes plus 90 minutes per stop (a fixed visit time).
   - Day 1 starts at the start. Day k starts at day k−1's last stop.
4. **The same places, always.** The optimizer only returns an order of the place ids it was given. The caller checks
   that the plan's place ids after the change are exactly the ones before (same set, same count). If not, nothing is
   changed and the result is `PLAN_CHANGED` (a bug guard; it should never happen).

## 28. Where the plan is ordered

1. **The start.**
   - The stop the driver named, if any (item 3).
   - Else the phone's position (the same usable fix as `navigate_to`, or the demo point in 模拟导航).
   - Else nothing: no change, result `NO_START`, and she asks 「从哪里出发？」.
2. **`make_trip_list`** orders the new plan: after its lookups, the whole plan is ordered and cut into days as §27
   item 3, with D = the number of `days` groups (1 for `places`). When the times fail, the plan is kept in the order
   asked and `next` says it is not ordered yet.
3. **`edit_trip_list action=reorganize`** (new) orders the whole current plan again.
   - Optional `start`: a name of a stop **in the plan**, matched as `remove` by name (§5.2). No match →
     `NOT_FOUND`; several → `AMBIGUOUS`. A name not in the plan is never searched on 高德.
   - Optional `days`: 1–5.
   - Visited and skipped stops (§29) are left out and keep their days; only the stops still to go are reordered.
   - No 高德 place search, no new place, no place removed or replaced (§27 item 4).
4. **`edit_trip_list action=move` with `to_day`** (new): moves stop `index` of the current day to the end of day
   `to_day`, then that day is ordered as §27 item 1 from its first stop. 「把珠海那个放到第一天」 is a `reorganize`
   with `start`, or moves, as she chooses.
5. **Saved plans are not changed.** Only the current plan changes; a saved plan changes on `trip_plans save`.
6. **She sees the places.** The results of `trip_plans open`, `edit_trip_list` and `make_trip_list` carry `plan`:
   each day's stop names in order, with `visited` / `skipped` marks.

## 29. One stop at a time

1. **`trip_next`** (new tool, replaces `route_trip`):
   - Optional `day` (1–5); optional `stop`: a stop name in the plan or its number in that day.
   - It starts guidance to one stop: the next one of the current day that is not visited or skipped, or the one asked.
     The route is a normal single-destination route from here, through the same route start as a chosen
     `navigate_to` place (F-15a), with no 高德 place search.
   - A running guidance is replaced, as 「换成X」 does today.
   - Result: `status: trip_next`, the stop's index, name, `distance_km`, `duration_min`, and the stop after it.
   - All of the day done: `DAY_DONE`, `next` asks whether to start the next day.
2. **Visited.**
   - Guidance that ends `arrived` at the stop marks it `visited`.
   - Guidance ended early does not mark it.
   - `edit_trip_list action=visited index` (「已经去过了」) and `action=skip index` (「跳过这个」) mark it by voice. Marks
     are kept in `current.json`; `reorganize` and `trip_plans open` keep them; `make_trip_list` starts with none.
3. **On arrival** a silent note in the §13 item 4 form is sent when a session is connected:
   > [系统] 已到达第k站名字。下一站是名字，约x分钟。问司机要不要现在去下一站。
4. **Screen.**
   - The card row stays as §11, with each card showing the driving minutes from the stop before (from §26, when
     known). Visited cards are greyed and marked 已到; skipped ones 跳过.
   - 「串成路线」 and 「开始导航」 are replaced by one button 「去下一站：名字」 (`trip_next`). Not moving only, as §11.
   - Pins as §13 item 5, without 途经 labels; visited pins are greyed.

## 30. Removed

- `route_trip`, its `order`, the kept trip route and its drop rules (§5.3, §20 items 2, 3, 9).
- Trip 途经点 in `RouteRequest.waypoints` and `TripStopTracker` (§6). `navigate_to` is unchanged.
- `TripOrder.nearest` (straight-line ordering).
- T-040k (phase 3 during guidance) is withdrawn: 「先去X」 and 「跳过」 are §29.

## 31. Catalog text

- `make_trip_list`, appended: 「清单会按司机现在的位置和真实车程自动排好顺序、分好天。」
- `edit_trip_list`, appended: 「「重新排一下」「从横琴开始重新排」→reorganize（start 填清单里的地点名，days 填天数）；「把X放到第二天」→move 加 to_day；「已经去过了」→visited；「跳过这个」→skip。按结果的 plan 说每天去哪。NO_START=问司机从哪里出发。」
- `trip_next`: 「行程按站导航：「开始第一天」「去下一站」「先去长隆」→trip_next（day、stop 可选）。一次只导航到一个地点。按 next 说一句；DAY_DONE=问要不要开始下一天。」
- `trip_plans`: 「打开后要导航就调用 trip_next。」 replaces 「打开后要导航就再调用 route_trip。」

## 32. Record and log

Codes and numbers only (I-8).

| Line | When |
|---|---|
| `trip order ok=<yes\|no> stops=<n> days=<n> start=<here\|named\|demo\|none> requests=<n> cached=<n> ms=<ms>` | After each ordering (make, reorganize, move to a day). |
| `trip next index=<k> day=<d> ok=<yes\|no> code=<c>` | After `trip_next`. |
| `trip visit index=<k> day=<d> by=<arrival\|voice\|skip>` | When a stop is marked. |

New error codes: `ROUTE_TIMES_UNAVAILABLE`, `NO_START`, `PLAN_CHANGED`, `DAY_DONE`. Each gets a `ToolFailureAdvice`
sentence.

## 33. Phase 3 acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 65 | 4 stops with a fixed time table where straight-line order differs from driving order | The order with the smallest total driving time; equal totals keep the current order | unit |
| 66 | 10 stops (fixed table) | Nearest + 2-opt result no longer than nearest alone; every stop once | unit |
| 67 | Named start 长隆 among 3 stops | 长隆 first; the rest by driving time from it | unit |
| 68 | 6 stops, 3 days | Consecutive days of ≥ 1 stop; the longest day (driving + 90 min per stop) is the smallest possible | unit |
| 69 | Any reorganize | The place ids before and after are the same set and count; a faked optimizer returning another id → `PLAN_CHANGED`, plan unchanged | unit |
| 70 | `reorganize start=环宇城` on a plan without it; with two stops containing it | `NOT_FOUND` with no 高德 search; `AMBIGUOUS` | unit |
| 71 | No position, no `start` | `NO_START`, plan unchanged, no 高德 request | unit |
| 72 | One pair's time fails after retries | `ROUTE_TIMES_UNAVAILABLE`, plan unchanged | unit |
| 73 | Reorganize twice within 30 min | The second makes no 高德 request; `trip order ... cached=` | unit |
| 74 | `make_trip_list days=[[A,B],[C]]` with a table that puts A and C close | The plan comes back ordered and cut into 2 days by §27; `plan` in the result | unit |
| 75 | `move index=2 to_day=1` | The stop ends on day 1, ordered; the place set unchanged | unit |
| 76 | `trip_next` on a day with stop 1 visited | Guidance to stop 2, single destination, no waypoints; result names stop 3 as the one after | unit |
| 77 | Guidance ends `arrived` at the stop; guidance stopped early | First: `visited`, the arrival note sent; second: no mark | unit |
| 78 | All of the day visited or skipped: `trip_next` | `DAY_DONE` | unit |
| 79 | `trip_plans open` | Result has `plan` with every day's names and marks | unit |
| 80 | The declarations | No `route_trip`; `trip_next` declared; the §31 texts present | unit |
| 81 | Device, 模拟导航 at 香洲: 「规划珠海一日游，去长隆、环宇城、渔女」 | Ordered by driving time from 香洲 (not 长隆 first); record line `trip order ... start=demo` | D |
| 82 | Device: 「从横琴开始重新排一下」, then 「开始第一天」, arrive, 「去下一站」 | 长隆 first; guidance to one stop at a time; she asks about the next stop on arrival; no place added, lost or changed | D |
| 83 | Device: a 3-day plan, 「把珠海那个放到第一天，然后重新排一下」 | One `reorganize` (or moves) call; 珠海's stops on day 1; she says each day's places | D |

## 34. Phase 3 tasks

| Task | Scope | Status |
|---|---|---|
| T-040n | §25–§32, rows 65–83 | Built 2026-11-17 (`TripOptimizer`, `TripTimes`, `AmapWebClient.drivingTimes`, `trip_next`; `route_trip`, 途经点 and `TripStopTracker` removed); rows 81–83 device |

# Phase 4: trips abroad, airport and hotels (T-040o)

Owner decisions 2026-11-18, after device run 079f455 (record 20261118-085853): place search abroad goes to Apple's own
search, picked by code from a China / outside-China flag ("probably the place belong to china and outside china
only"); a trip has a start, hotels and an end; the start is what the driver names, else the current position ("if
user dont mentioned would be using current location otherwise use what user mentioned"). "ok i trust you write the
spec and push to remote".

## 35. Why

「帮我安排一个东京五天的自驾游行程，我在成田机场下飞机，之后也在成田机场上飞机，酒店、机场到酒店都给我安排一下」
(heard correctly by both recognizers):
- `make_trip_list days=[[浅草寺,东京晴空塔],…]` (11 Tokyo names): 9 `not_found` (`nomatch` 4, picker `none` 5). The 2
  "found" were places in China.
  - 高德 Web search has no Japan places. Checked 2026-11-18 with an owner test key: `/v5/place/text` and
    `/v3/place/text` for 东京晴空塔, Tokyo Skytree, 浅草寺, 新宿御苑, 成田机场 all return `count=0`; `/v3/geocode/geo`
    returns `ENGINE_RESPONSE_DATA_ERROR`.
  - 高德 driving routes do cover Japan: `/v3/direction/driving` 成田机场 → 浅草 returned 63.1 km, 3,881 s.
- No airport, no hotel: `make_trip_list` has no field for a start, an end or a night's stay; she dropped them.
- `trip order … start=here`: the Tokyo plan was ordered from the phone in 珠海.
- Her first reply drifted into Thai mid-sentence (`correction WRONG_LANGUAGE heard=none`); the re-ask then made her say
  「请您用中文再说一遍您的需求」 although both recognizers had the words (F-05a §4 item 4 has no text when there is no
  SenseVoice final; this run used `asr=stream`).

**Sources (read 2026-11-18).**
- Code builds the frame and the order; the model only names places and writes the speech:
  [TravelPlanner](https://arxiv.org/pdf/2402.01622) (language agents alone 0.6 % success),
  [ChinaTravel](https://arxiv.org/pdf/2412.13682v3) (neuro-symbolic 27.9 % vs 2.6 % constraint pass),
  [ItiNera](https://alphaxiv.org/abs/2402.07204) (LLM–solver–LLM).
- The hotel as each day's anchor, placed near the day's places: [TourPlanner](https://arxiv.org/html/2601.04698v1)
  (accommodation around the POI centroid), [ItinerAI](https://ai.google.dev/competition/projects/itinerai).
- Apple place search: `MKLocalSearch` with `naturalLanguageQuery` and a `region`; results are `MKMapItem` with
  `placemark.isoCountryCode` ([Apple MKLocalSearch](https://developer.apple.com/documentation/mapkit/mklocalsearch)).
  No key, no fee; Apple throttles heavy use (`MKError.loadingThrottled`).
- Apple Maps hand-off: `MKMapItem.openMaps(with:launchOptions:)` with `MKLaunchOptionsDirectionsModeDriving`
  ([Apple](https://developer.apple.com/documentation/mapkit/mkmapitem/openmaps(with:launchoptions:))).
- 高德 abroad: 高德 announced a developer 世界地图 service (2025-07, upgraded 2026-07,
  [IT之家](https://www.ithome.com/0/869/240.htm), [新浪](https://finance.sina.com.cn/tob/2026-07-07/doc-inifyzkw5093066.shtml));
  the owner's Web key does not have its place search (above). If 高德 opens it later, only §36 item 2 changes.

## 36. China or abroad

1. **`abroad`** (new, `make_trip_list`): `true` when the trip is outside China, `false` (default) otherwise. China
   here is the mainland, Hong Kong, Macau and Taiwan (高德's coverage); a 珠海 → 澳门 trip is `false`. The model sets
   it from the request; the vendor is never named to the model.
2. **Search by flag (code).** `abroad=false`: 高德 as today (§4). `abroad=true`: every name (places, `start`, `end`,
   `hotels`) goes to `ApplePlaceSearch` (§41), with the region of the first found name, else no region.
3. **Wrong-country guard.** In an `abroad` trip, an Apple result whose `isoCountryCode` is CN, HK, MO or TW is
   dropped (`reason=country`). Several results for a name go to the picker as §4 item 6.
4. **Wrong-flag backstop.** `abroad=false` and 高德 finds fewer than half of the names: those names are searched on
   Apple. If most Apple results are outside China, the trip becomes `abroad`, every name is searched again as item 2,
   and the record line says `switched=yes`.
5. **Coordinates.** Outside China, GCJ-02 equals WGS-84; Apple results are used as they are. Inside China nothing
   changes (高德 only).
6. **Driving times** stay on 高德 `/v3/distance` (§26) in both cases. Abroad, if 高德 does not answer every pair,
   §26 item 4 applies (`ROUTE_TIMES_UNAVAILABLE`, kept in the asked order); straight-line ordering is still never used.
7. **Photos and introductions.** Abroad, §12 photos are skipped (高德 has none there); the §21 introduction from the
   Qwen web search works as it does at home.

## 37. Start, hotels and end

1. **New `make_trip_list` fields:**
   - `start`: optional name, ≤ 40 characters (「成田机场」).
   - `end`: optional name, ≤ 40 characters.
   - `hotels`: optional, 1–4 names; one name is the base for every night; D−1 names are one per night, night k
     after day k. Any other count → `invalidFields`.
   They are searched as places (§36 item 2) and are not counted in the 16. One not found → it is left out, named in
   `not_found`, and the plan is built without it.
2. **Roles.** Each plan stop gets `role`: `start`, `sight` (today's stops), `hotel` or `end`. `start` is day 1's first
   stop; `end` is the last day's last stop; night k's hotel is day k's last stop and day k+1's first stop (the same
   place id on both days). §27 item 4's same-place check counts the roles too.
3. **Ordering with fixed ends (§27 extended).** Each day is an open path with a fixed first stop (`start`, or the
   hotel of the night before) and, when there is one, a fixed last stop (that night's hotel, or `end` on the last day).
   - The sights are first put on one path and cut into D days as §27 item 3, with `start` fixed first and `end`
     fixed last.
   - Then each day is ordered again between its fixed ends (§27 item 1).
4. **Hotels picked by code.** A trip of 2–5 days with no `hotels`: for each night k, code searches 「酒店」 within
   3 km of the midpoint of day k's last sight and day k+1's first sight (高德 at home, Apple abroad), takes the first
   result, and reorders days k and k+1 as item 3. None within 3 km → 10 km → no hotel for that night, and `next`
   says so. Picked hotels are marked `picked: true`; the driver changes one with `edit_trip_list replace`.
5. **The start rule** (replaces §28 item 1 for `make_trip_list`):
   - `start` named → there.
   - Else the phone's position (or the demo point), **when it is within 300 km of a sight**.
   - Else `NO_START`: the plan is kept unordered and she asks one question: 「从哪里出发？机场还是酒店？」.
     The answer comes back as `edit_trip_list reorganize start=…`; a `start` not in the plan is searched once (as a
     place of the trip, §36 item 2) and added with `role: start`.
   `reorganize` keeps the plan's `start` unless a new one is named; with neither, §28 item 1 applies with the same
   300 km rule.
6. **End rule.** `end` named → the last day ends there. Else the last day ends at its last sight.
7. **`trip_next`** goes to every stop in order, hotels and `end` included; arriving at a night's hotel ends the day
   (`DAY_DONE` on the next `trip_next` of that day).
8. **Screen.** Hotel and airport cards carry a small label 住 / 机场 under the poster; day 1's first card and the last
   day's last card are the start and the end.

## 38. Guidance abroad

1. `trip_next` and `navigate_to` start 高德 guidance as today.
2. Abroad (`abroad=true` trips, or a destination whose coordinates are outside China), if 高德's route calculation fails,
   the app opens Apple Maps with driving directions to that stop (`MKMapItem.openMaps`) and says 「已在苹果地图打开导航」.
   The stop is not marked visited by the app; 「已经到了」 marks it (§29 item 2).
3. Device row 97 settles whether 高德 guidance works in Japan. If it does, item 2 never fires.

## 39. Catalog text

- `make_trip_list`, appended: 「行程在中国以外（不含港澳台）时填 abroad=true。司机说了从哪里出发、在哪里结束就填 start、end（比如机场）；说了住哪里就填 hotels（一个=每晚都住这家，或每晚一个）；没说酒店就不填，会自动挑。没说起点就不填。NO_START=问司机从哪里出发。」
- `edit_trip_list`, appended: 「司机回答从哪里出发→reorganize 填 start。」
- `trip_next`, appended: 「已在苹果地图打开=告诉司机，到了说「已经到了」。」

## 40. The re-ask when the reply drifts (F-05a §4 item 4)

The 「请用中文简短地请司机再说一遍」 form is used only when the utterance has no text at all. Otherwise the re-ask
carries the driver's words from, in order: the SenseVoice final, the streaming local final (`heard-local`), Gemini's
input transcript (`heard-gemini`): 「…司机刚才说的是「<文字>」。请用中文回答这句话。」. The record line becomes
`correction WRONG_LANGUAGE heard=<sensevoice|local|gemini|none>`. F-05a's own rows keep passing (the SenseVoice form
is unchanged).
Build note (T-040o): SenseVoice is removed from the app (F-05a §16 row 7, enforced by `check_imports.py`), so no
utterance has a SenseVoice final and `heard=sensevoice` is never written; the sources in use are `local` and
`gemini`.

## 41. Code

- **NovaPorts:** `PlaceSearch` gains a second implementation; a `TripRegion` value (`china`, `abroad`) chooses it in
  NovaNav. `Place` gains `countryCode: String?`.
- **NovaPlatform:** `ApplePlaceSearch` (`MKLocalSearch`, 8 s limit, at most 2 at once, one retry on
  `loadingThrottled` after 1 s). `MapKit` is added to §3.2 of ios-architecture.md as NovaPlatform and App only;
  `check_imports.py` enforces it.
- **App:** `AppleMapsHandoff` (`MKMapItem.openMaps`).
- **NovaNav:** `TripPlanner` roles, `TripOptimizer` fixed last stop, hotel picking, the 300 km start rule.
- **NovaVoice:** §40.

## 42. Record and log

Codes and numbers only (I-8).

| Line | When |
|---|---|
| `trip search vendor=<amap\|apple> abroad=<yes\|no> switched=<yes\|no> names=<n> found=<n> country_dropped=<n> ms=<ms>` | After a trip's lookups. |
| `trip frame start=<named\|here\|demo\|none> end=<named\|none> hotels=<named\|picked\|none> nights=<n> picked=<n>` | After a plan is built or reorganized. |
| `trip handoff vendor=apple_maps reason=<route_failed>` | When §38 item 2 opens Apple Maps. |

`trip lookup … reason=` gains `country`. `trip order … start=` keeps its values. New code: none (`NO_START` is §32's).

## 43. Phase 4 acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 84 | `make_trip_list abroad=true` with 3 names (fake Apple search) | All lookups go to Apple, none to 高德; `trip search vendor=apple` | unit |
| 85 | `abroad=true`, Apple returns a CN result and a JP result for one name | The CN one is dropped (`reason=country`); the JP one is kept | unit |
| 86 | `abroad=false`, 高德 finds 2 of 11, Apple finds 10 of 11 in JP | The trip switches to abroad; every name searched on Apple; `switched=yes` | unit |
| 87 | `abroad=false` 珠海 → 澳门 names, 高德 finds them all | No Apple search | unit |
| 88 | `start=成田机场 end=成田机场 hotels=[A]`, 5 days, 10 sights (fixed table) | Day 1 starts at 成田 and ends at A; days 2–4 start and end at A; day 5 starts at A and ends at 成田; every sight once | unit |
| 89 | 3 days, `hotels=[A,B]` | Night 1 = A (day 1 last, day 2 first); night 2 = B | unit |
| 90 | `hotels` with 3 names on a 3-day trip | `invalidFields` | unit |
| 91 | 3 days, no `hotels` (fake search returns a hotel within 3 km) | Two hotels picked, `picked: true`; days reordered with them fixed; `trip frame hotels=picked picked=2` | unit |
| 92 | No `start`, phone 2,500 km from every sight | `NO_START`, plan unordered, no `/v3/distance` request | unit |
| 93 | No `start`, phone 20 km from a sight | Ordered from here, as phase 3 | unit |
| 94 | `NO_START`, then `reorganize start=成田机场` (not in the plan) | One search; added with `role: start`; plan ordered from it; the sights unchanged | unit |
| 95 | Reply blocked as Thai, no SenseVoice final, `heard-local` text present | The re-ask carries the local text; `heard=local`; no 「再说一遍」 | unit |
| 96 | Device, 模拟导航 off, in 珠海: the 2026-11-18 sentence (东京五天, 成田机场进出, 酒店都安排) | Every sight in Tokyo; day 1 from 成田, last day to 成田, a hotel each night; no 「再说一遍」 | D |
| 97 | Device: 「开始第一天」 on that plan | 高德 guidance to 成田 → first stop starts, or Apple Maps opens with `trip handoff` | D |
| 98 | Device: 「规划珠海一日游，去长隆、环宇城、渔女」 | Unchanged from row 81: 高德 only, `trip search vendor=amap abroad=no` | D |

## 44. Phase 4 tasks

| Task | Scope | Status |
|---|---|---|
| T-040o | §35–§42, rows 84–98 | PASS (56c5b5e); rows 96–98 device NOT_VERIFIED |
