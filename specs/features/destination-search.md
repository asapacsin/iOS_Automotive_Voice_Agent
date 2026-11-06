# F-16 Destination search and saved places

**Android status:** IMPLEMENTED (JVM + LIVE Amap Web). P53, P68 open.
**Depends on:** contracts/navigation.md, contracts/api-contracts.md (Amap Web)

## 1. Purpose
Turn a spoken place into up to 5 candidates near the driver, or along the route; answer 家/公司 from saved places.

## 2. User-facing behaviour
附近的加油站 sorts by distance; 珠海站 by weight; 家 uses the saved slot or says it is not set.

## 3. Preconditions
- Amap Web key saved (`AMAP_WEB_KEY_MISSING` otherwise).
- Location permission for nearby and along-route search; a fix counts as fresh for 30 s, provisional up
  to 10 min, accuracy ≤ 2000 m. Without a usable fix, text search (no city) is used.
- 家/公司 need the saved slot (`save_place`); otherwise `HOME_NOT_SET` / `WORK_NOT_SET` and no search.

## 4. Inputs and outputs
- In: the `navigate_to` destination string, or `query_live_info(kind=along_route)` while navigating.
- Query building: strip filler and navigation verbs (导航去, 带我去, 附近的); if the stripped query finds
  nothing, retry once with the verbatim text.
- Out: up to 5 `Place` {name, address, coordinate (GCJ-02), distance m when known}, ordered by distance for
  nearby/category queries (附近的加油站) and by Amap weight for named places (珠海站).
- Saved places return a single place without a POI search.

## 5. State transitions
Stateless per query; the resulting list enters F-15 (AWAITING_DESTINATION_SELECTION or route calculation).

## 6. Events and triggers
`navigate_to` (F-15), `query_live_info` along_route, `save_place`, first location fix (initial map recenter).

## 7. Dependencies and external services
Amap Web REST `/v3/place/text`, `/v3/place/around` (radius 50 000 m, ≤ 5 results);
CoreLocation (`CLLocationManager`), `CoordinateConverter` WGS-84 → GCJ-02; saved places in local storage
(already GCJ-02, not converted again).

## 8. Error handling and recovery
| Case | Code |
|---|---|
| Key missing / rejected (Amap infocode 10001 etc.) | `AMAP_WEB_KEY_MISSING` |
| Quota exceeded | `LIVE_INFO_QUOTA` |
| Network / non-OK response | `LIVE_INFO_UNAVAILABLE` |
| 0 results after verbatim retry | `NO_CANDIDATES` |
| Home / work not saved | `HOME_NOT_SET` / `WORK_NOT_SET` |
| Blank / too long destination | `BLANK_DESTINATION` / `DESTINATION_TOO_LONG` (validation) |
Keys and coordinates are never logged in full (I-8).

## 9. Concurrency, cancellation, timeouts
HTTP timeout per request follows the shared Amap Web client; a newer `navigate_to` makes older results
stale (F-15 generation). Along-route search while navigating keeps the current guidance; 0 results or
cancel restore it.

## 10. Acceptance criteria (iOS)
- Keyword stripping and verbatim retry produce the same queries as Android (unit, table-driven).
- 家乐福 is never treated as 家.
- Unset home → `HOME_NOT_SET`, no POI search.
- Coordinates converted to GCJ-02 before Amap calls; saved places are not converted.
- `save_place` claims success only when the slot reads back the found place, else `PLACE_NOT_SAVED`
  (unit, PROPOSED iOS row, I-1).

## 11. Existing Android tests
`T/nav/LiveDestinationCandidateSourceTest`, `DestinationQueryTest`, `AlongRouteCorridorTest`, `SavedPlacesTest`, `InitialLocationRecenterTest`.

## 12. Source references (Android)
`A/nav/LiveDestinationCandidateSource.kt`; `A/AmapPoiClient.kt:89-92,219-256`; `A/nav/AlongRouteCorridor.kt:89-96`; `A/nav/SavedPlaces.kt:13-30`; `A/nav/SavedPlaceStore.kt:14`; `A/nav/amap/AmapCoordinates.kt`; `A/CoarseLocationProvider.kt:31-37`; `A/nav/InitialLocationRecenter.kt:120-126`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
Amap Web REST is plain HTTPS (A). Location: `CLLocationManager`, convert WGS-84 → GCJ-02 (PROPOSED). Recenter thresholds: fresh 30 s, provisional 10 min, accuracy ≤2000 m.

## 14. No route to a nonsense place: near-first, sound-alike match, confirm by confidence (iOS, PROPOSED 2026-11-05)

**Why.** All 45 phone records, 2026-11-03 to 2026-11-05, car in 横琴. A misheard name plus the §7 nationwide fallback sends the car across the country:

| Record | Gemini's `destination` | What happened |
|---|---|---|
| `20261105-161701` | 横道河子口岸 (meant 横琴口岸) | 「第一个」 started a 2,935 km route; the same name was searched 3 more times |
| `20261105-152806` | 丽君广场 (meant 丽骏庞都) | Index 2, 丽君小镇, 1,830 km, 「大约1158分钟」 |
| `20261105-151937` | 丽骏庞都 | Listed 奢SPA; routed to it |
| `20261104-172300` | 横琴口岸 | Listed 新濠影汇 and two Macau hotels |
| `20261104-172300` | 玛格庙 (妈阁庙) | `NO_CANDIDATES` |
| `20261104-173126` | 创新坊 | Routed straight to 鸿运坊(澳门巴黎人) |

**Owner rule kept.** F-05a §6: no transcript is used for tool calls. Everything below uses only Gemini's `destination`, the car's position, 高德 data and app state.

Sources 2026-11-05:
- **Resolve a misheard name against a catalog of real places**, reranking by phonetic similarity: [entity resolution for noisy ASR](https://aclanthology.org/D19-3011.pdf). Chinese practice does this in pinyin: [拼音比对](https://blog.csdn.net/killyouworld/article/details/144139846).
- **Rank with the user's location:** [Google Places `locationBias`](https://developers.google.com/maps/documentation/places/web-service/text-search), [高德 POI 2.0](https://lbs.amap.com/api/webservice/guide/api-advanced/newpoisearch), [POI ranking patent](https://patents.google.com/patent/US20130262479A1/en).
- **Confirm by confidence; on a no, offer the next candidate; don't guess:** [VUI confirmations](https://voicefirstai.medium.com/5-confirmations-for-voice-user-interfaces-e9c9fd03c764), [US 7634357](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7634357), [arXiv 2607.26410](https://arxiv.org/pdf/2607.26410).
- **The numbers are ours** (PROPOSED). Row 1 replays the logged cases to set them.

**Rule in plain words.** Search near the car, match by sound and distance, say how far, and never route to a far or doubtful place without a yes.

1. **Search order.** All of these run near the car; none is nationwide:
   1. `/v3/place/around` from the car, 50 km.
   2. `/v3/place/text` with `city` = the car's adcode, `citylimit=true`.
   3. If `destination` ends in a place-type word (口岸, 广场, 机场, 站, 医院, 酒店, 学校, 公园, 大厦, 中心, 庙, 坊, 镇, 小镇), an around search for that word.

   Nationwide text search runs only when `destination` contains a province or city name other than the car's, or when all three find nothing.
2. **Score.** Each candidate gets pinyin similarity to `destination` plus a distance prior.
   - **Pinyin similarity:** the share of matching syllables without tones.
   - **Distance prior:** `distanceWeight` (PROPOSED 0.15) within 3 km, falling linearly to 0 at 50 km.
   - **Order.** Candidates are listed by score.
   - **The pinyin conversion is a port.** On iOS it uses Foundation's Mandarin→Latin transform. Pure logic stays in `NovaCore`.
3. **Confirm by score.** Using the top score `s1` and the runner-up `s2`:
   - **Sure:** `s1 ≥ sureMin` (0.8) and `s1 − s2 ≥ 0.2`. `next`: 「找到X，在N公里外，说第一个就去，或说第几个。」
   - **Unsure:** `s1 ≥ askMin` (0.5). `next`: 「是去X吗？在N公里外。」
   - **No fit:** `NO_CANDIDATES`, with the advice to ask where again without repeating the misheard name.
4. **Far places.** A candidate over `farKm` (PROPOSED 300 km) from the car gets status `far_only`, with `next` 「附近没找到X，最近的在N公里外的Y，要去那里吗？」. Y is its city.
5. **No route without a yes, in code.**
   - **A route needs a separate yes** for an unsure, far or no-fit candidate. `choose_navigation_option` and the start for that candidate are refused with `CONFIRM_FIRST` until a later driver turn, as counted by the uplink gate (F-04a), with her question in between.
   - **Words are not checked** (F-05a §6). Gemini's call on the next turn is the yes.
6. **On a no, the next candidate.**
   - **The next candidate.** When the driver says no to item 3's or item 4's question, the next call with the same `destination` returns the next candidate by score, once.
   - **Then refusal.** After that, the same string returns `DESTINATION_REJECTED` with 「这个地名刚被否定了，请问司机要去哪里。」
7. **Every result says where.** Each candidate carries its city or district (`cityname`/`adname`) and `distance_km`.
8. **The start sentence.** It gives the name, the km, and the duration in hours and minutes once it reaches 60 minutes: 「去X，约N公里，1小时35分钟」. A route over `farKm` adds 「这是长途，确定吗？」, and the route is cancelled on a no.
9. **Record.** One line per call: `dest-search destination=<name> step=<around|city|type|country> n=<n> top=<name> score=<s1> km=<n> check=<sure|ask|far_only|none|rejected>`. `RuntimeLog` gets `destSearch step=<...> check=<...>` only, with no names (I-8).
10. **Not changed.** Saved places, `附近的X` category searches, along-route search, and F-05a §6.
11. **Not fixed here.** Gemini mishearing in the first place, and car actions on misheard words (F-05a, F-12).

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | PC, car at 横琴 (113.54, 22.13), live 高德: replay the 6 logged `destination`s | Note candidates, scores, tier, km; expected 横琴口岸, 妈阁庙 and 创新坊 near the car, and no far route without a question; the owner sets the numbers | PC |
| 2 | Score on the logged pairs; shuffled 高德 order | Ranked by score; tiers as item 3 | unit |
| 3 | Only far candidates; `destination` names their city | `far_only`; listed normally with km | unit |
| 4 | `choose_navigation_option` on an unsure or far candidate in the same turn; on the next driver turn | `CONFIRM_FIRST`; runs | unit |
| 5 | A no, then the same `destination` twice | The next candidate; `DESTINATION_REJECTED` | unit |
| 6 | Routes of 6 min, 95 min and 2,935 km | 「约6分钟」; 「1小时35分钟」; the km plus the long-trip question | unit |
| 7 | Record and log | Item 9 lines; no names in `RuntimeLog` | unit |
| 8 | Device at 横琴: 「导航到横琴口岸」, 「导航到妈阁庙」, 「导航到丽骏庞都」, each 3 times | No route over `farKm` without a yes; note what was first | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-042c | Items 1–11; rows 1–8 | unit, PC, D |
