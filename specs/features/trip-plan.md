# F-15b Trip list and multi-stop route (打卡清单 → 串成路线 → 途经点导航)

**Status:** APPROVED for phase 1 (owner 2026-11-16, after the proposal: "good then you just write a spec and push to
remot"). iOS only. Phase 1 is voice only. Phases 2–3 (§10) are not started: each needs the owner's request.
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

NovaDrive (code at 5d7486a) can only take one destination:
- `navigate_to` → pick → route → guidance.
- `RouteRequest` holds only `destination` and `destinationName`.
- `AmapRouteEngine.fetch` sends only `origin` and `destination` to `/v3/direction/driving`.
- Nothing keeps a list of places between turns. The model's memory is the only "list", and it is gone after a session
  restart.

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
   - An app restart empties it.
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
2. **Match rule.**
   - The first result is accepted only when, after `TranscriptText.normalize`, its name contains the asked name or
     the asked name contains its name.
   - Otherwise the name is **not found**. No guess, no sound-alike pick: the names come from the model as text, not
     from speech.
3. **Duplicates.** A result whose `Place.id` is already in the list is dropped. Its name is reported in `duplicates`.
4. **Limits.**
   - At most 4 lookups run at once.
   - Each lookup uses the transport's 8 s timeout.
   - The whole `make_trip_list` call finishes within 15 s. Lookups still running then count as not found, with
     `reason=timeout` in the record.
5. **No key.** A missing or rejected key returns `AMAP_WEB_KEY_MISSING`. Any other lookup failure counts as not found.

## 5. Tools (F-09 catalog)

### 5.1 `make_trip_list`

**Arguments:**
- `places`: 1–16 strings, each 1–40 characters.
- `city`: optional, ≤ 20 characters.

**Use.** 「做个打卡清单」「把这些地方列出来」. The model passes the places it just suggested.

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
> 把刚才推荐的地点做成打卡清单：「做个打卡清单」「列个清单」「把这些地方存下来」。places 填地点名（最多16个，每个只写地名，不写介绍），知道城市时填 city。会替换旧清单。按结果答：只说清单有几个地点；not_found 里的地点说没找到；不要念整张清单，司机问时再念。

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
   - "One trip at a time" (F-15a §9) holds: a running trip is stopped first.
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
> 把打卡清单串成一条自驾路线（多个途经点）：「串成自驾路线」「规划一下路线」→start=false；看过路线后「开始导航」「出发」→start=true；「按清单顺序走」→order=as_listed，默认 nearest（就近排序，清单会按路线顺序重新编号）。只有一个地点时用 navigate_to。按结果答：按 next 说；不要念每个地点；ok=false 按 error：NO_TRIP_LIST=还没有清单，TRIP_TOO_SHORT=至少要两个地点，ROUTE_CALCULATION_FAILED=路线规划失败，START_FAILED=导航没有启动，不要说已开始。

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

- Showing the list or numbered pins on screen (phase 2).
- Adding, skipping or reordering stops during guidance (phase 3).
- Per-stop arrival announcements and "next stop" questions (phase 3).
- Photo cards: slow, data-heavy, and not to be looked at while driving. Not planned.
- Planning by day (「第一天」): the model may talk about days, but one route is one drive.
- Ratings: `Place` has no rating, and getting one costs a detail call per stop.

## 9. Acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `make_trip_list` with 8 names; the fake search finds 7, and the 8th's first result has an unrelated name | `trip_list` count 7, indexes 1–7, `not_found` = the 8th; one `trip lookup … reason=nomatch` line | unit |
| 2 | Two names resolve to the same `Place.id` | One stop; the other is in `duplicates` | unit |
| 3 | 17 names; a blank name | `invalidFields`; the list is unchanged | unit |
| 4 | A list of 5: `remove index=2`, then `remove name=古文化街` (one match), then `move index=4 to_index=1`, then `replace index=9` | Renumbered 1…n after each; the last returns `OUT_OF_RANGE` and changes nothing | unit |
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
| T-040j | Phase 2: the list card on screen (name, district, distance), numbered pins on the map, 途经1…N on the route line. Not started: needs the owner's request after T-040i row 15 passes | — |
| T-040k | Phase 3: during guidance, 「加一个加油站」 (inserted at the best place), 「跳过下一站」, 「先去X」, next-stop questions and per-stop arrival, re-routed from here. Not started: needs the owner's request | — |

Trace ids: T-040i is added to `specs/trace-ids.txt` (F-15b) with its tests, not before, so spec-trace stays green.
