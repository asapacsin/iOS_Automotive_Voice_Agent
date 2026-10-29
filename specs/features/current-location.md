# F-16a Use the phone's real location (位置来源, 「我现在在哪？」)

**Status:** APPROVED (owner request 2026-10-27: "the app can't use the local address, solve this on the spec").
iOS only. Extends [F-16 Destination search and saved places](destination-search.md) and
[F-18 Live info](live-info.md). Defaults below are decided; OQ-LOC-1/2 stay open with the recommended
answer used until the owner says otherwise.
**Depends on:** F-16 (T-042 `CoreLocationProvider`), F-18 (T-046), F-22 (settings), F-23 (permissions),
contracts/api-contracts.md

## 1. Problem (device run 2026-10-27, build 046af07)
- The app always uses the fixed demo start point (珠海市人民政府, `DemoLocation`). The setting
  `use_device_location` exists in `AgentRuntime` but **no screen can turn it on**, so the phone's own position
  is never used for nearby search, weather "here" or the route origin.
- 「我现在在哪里？」 has **no tool**: the model answered 「抱歉，我没有获取您当前具体位置的权限。」, a claim
  nothing supported (I-1).
- `CoreLocationProvider.latestFix()` returns nil on its first call (no wait for the first fix), and an
  authorization change is not handled, so the first request after granting permission still has no position.

## 2. User-facing behaviour
- **设置 → 位置来源** (new section) with two choices:
  - **手机定位** (default): the phone's GPS position via CoreLocation.
  - **演示起点**: the fixed demo start point, for screen recordings (demo-recording.md REC-003, no private
    address in the video).
  Under the choice: the permission state (已允许 / 未允许 / 未询问) and, when not allowed, a button
  **打开系统设置** (`UIApplication.openSettingsURLString`).
- The drive screen header shows a small label when the demo point is in use: **演示位置** (next to 模拟车辆),
  so a viewer is never misled about where the car is.
- Choosing 手机定位 asks for When In Use permission at once (if not asked yet); the map recenters on the first
  fix (F-16 initial recenter rules).
- Voice: 「我现在在哪？」「这是哪里？」「我在什么路上？」 → she says the address from the lookup, in one sentence:
  「你现在在珠海市香洲区情侣中路附近。」 With the demo point: 「现在用的是演示起点，在珠海市人民政府附近。」
- Nearby search (「附近的加油站」), weather "here" and the route origin all use the **same** source as the
  answer above; the source switch takes effect for the next request, without restarting the conversation.

## 3. Preconditions
- `NSLocationWhenInUseUsageDescription` (already in `project.yml`). No Always permission, no background location.
- An Amap Web key for the address lookup (F-16); without it the coordinates are still used for routing and
  search, but 「我在哪」 answers `AMAP_WEB_KEY_MISSING` honestly.

## 4. Inputs and outputs
- New `query_live_info` kind **`current_location`** (F-18 catalog enum gains it; no other argument).
- Result: `{ok:true, address, district, road?, accuracy_m, source: "device"|"demo", fix_age_s}`.
  - `address` = Amap regeo `formatted_address` (GCJ-02 point after `CoordinateConverter`), trimmed of the
    province when it equals the city (「广东省珠海市…」 → 「珠海市…」).
  - The model speaks only from `address`/`road`; `next`: 「只按 address 用一句话回答；source 是 demo 时说这是演示起点。不要编造。」
- Fix rules (F-16 §3): fresh ≤ 30 s, provisional ≤ 10 min, accuracy ≤ 2000 m; an older or coarser fix is not used.
- `latestFix()` waits **up to 3 s** for the first fix after start (configurable `TuningDefaults.firstFixWait`)
  instead of returning nil at once.

## 5. State transitions
Location source: `demo | device(notDetermined → authorized | denied)`. Authorized → updating; app background →
updates paused (When In Use); foreground → resumed. Switching source in 设置 swaps the provider behind one
`SwitchableLocationProvider`; no request in flight is affected (it keeps the fix it already read).

## 6. Events and triggers
Settings choice, permission answer (`locationManagerDidChangeAuthorization`), scene phase, `query_live_info`
`current_location`, any nearby/weather/route request that reads the position.

## 7. Dependencies and external services
- `CLLocationManager` in NovaPlatform/Location (I-9). It handles `locationManagerDidChangeAuthorization`:
  authorized → `startUpdatingLocation`; denied/restricted → `denied = true`, latest fix cleared.
- Amap Web `/v3/geocode/regeo` (`AmapWebClient`): new `address(at:)` next to `adcode(at:)`, same request,
  reads `formatted_address`, `addressComponent.district`, `streetNumber.street`.
- `SwitchableLocationProvider` (pure, NovaNav) reads the source from a closure so the app's setting drives it.

## 8. Error handling and recovery
| Case | Code | What she says (advice) |
|---|---|---|
| Permission denied / restricted | `LOCATION_PERMISSION_DENIED` (new) | 「定位权限没有打开，可以在设置里允许。」 |
| No fix within 3 s, or fix too old/coarse | `NO_LOCATION` | 「现在还没定位到，稍后再问我。」 |
| No Amap key | `AMAP_WEB_KEY_MISSING` | F-18 advice |
| regeo network/timeout (4 s) | `NO_LOCATION` (F-18 §8 "regeo failed") | as above |
| Quota | `LIVE_INFO_QUOTA` | F-18 advice |
She never says she lacks permission unless the result code says so (I-1). Codes only in logs; coordinates and
addresses are never logged (I-8).

## 9. Concurrency, cancellation, timeouts
First-fix wait 3 s, regeo 4 s (F-18), one regeo per question, no retry inside a turn. The source switch is
read once per request.

## 10. Acceptance criteria (iOS)
| # | Criterion | Level |
|---|---|---|
| 1 | 设置 shows 位置来源 with 手机定位 default; choosing it asks permission once; the state line follows the answer | S, D |
| 2 | With 手机定位 allowed, 「我现在在哪？」 → one `query_live_info(current_location)`, she says the regeo address of the real position | D |
| 3 | 「附近的加油站」 and weather "here" use the phone's position (distances in the list match the real place) | D |
| 4 | With 演示起点, the header shows 演示位置 and the answer says 演示起点 | S, D |
| 5 | Denied → `LOCATION_PERMISSION_DENIED`, the sentence from §8, no address claimed; 打开系统设置 opens the app's page | unit, D |
| 6 | First request right after permission is granted gets a fix (waits ≤ 3 s), not `NO_LOCATION` | unit (fake manager), D |
| 7 | `current_location` result shape, province trimming, `source`, stale/coarse fix refused | unit |
| 8 | No coordinate or address appears in logs (log capture during row 2) | D |

## 11. Implementation constraints
- CoreLocation only in NovaPlatform/Location; the result shape, freshness rules and the switchable provider are
  pure Swift in NovaNav with fakes.
- The catalog change (`current_location` in the kind enum, description lists 「我在哪」) updates the catalog
  golden test; Persona text gets one line: location questions go to `query_live_info current_location`.
- The demo recording keeps using 演示起点 (REC-003); the evidence sheet notes the source.

## Open questions
- OQ-LOC-1 (default: **手机定位**): should a fresh install start on 手机定位 or 演示起点? Recommendation: 手机定位,
  since the demo source is only for recordings.
- OQ-LOC-2 (default: **no**): should 「我在哪」 also show the point on the map with a pin? Recommendation: no; the
  map already follows the position. **Superseded 2026-10-28:** it did not; the map position is specified in
  [F-16b](map-current-location.md).

## Tasks (implementation-plan.md M3, specs/work.json)
| ID | Task | Verification |
|---|---|---|
| T-042a | `CoreLocationProvider`: first-fix wait, authorization-change handling, denied state; `SwitchableLocationProvider` | unit, build |
| T-042b | 设置 → 位置来源 section, permission state, 打开系统设置; 演示位置 header label | S, D |
| T-046a | `query_live_info` `current_location`: `AmapWebClient.address(at:)`, result/codes, catalog + persona line | unit, contract, D |
