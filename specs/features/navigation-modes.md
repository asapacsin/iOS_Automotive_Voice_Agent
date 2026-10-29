# F-15a Real navigation by default, simulation as a separate mode (真实导航 / 模拟导航)

**Status:** APPROVED 2026-10-29 (owner: "Approve defaults"; OQ-NAVM-1 no voice switch, OQ-NAVM-2 refuse without a fix, OQ-NAVM-3 foreground only, OQ-NAVM-4 web route + own matching). iOS only. Owner report 2026-10-29 (device run
aba6829): "During navigation, it's supposed to follow the current location, yet this just shown two locations, keep
switching between two locations, and simulate navigation even though I'm not asking about that." Owner direction
2026-10-29: real navigation is the default; simulation stays, as a separate mode chosen by a switch.
**Supersedes:** F-16b OQ-MAP-2 for 真实导航 (there the simulated car stood for 我的位置; it still does in 模拟导航).
**Depends on:** F-15 (navigation flow, `NaviEngine`, `NaviMode`), F-16 §3 (usable fix), F-16a (`LocationUpdates`,
`SwitchableLocationProvider`), F-16b/F-16b.1 (`SelfPosition`, `MapCameraPolicy`), F-14 (guidance relay), F-17 (HUD),
F-09 (guards), F-04a (uplink gate: driver turns), contracts/navigation.md, contracts/api-contracts.md
**Revised 2026-10-29:** §2.5 no longer reads the driver's transcript (owner rule: transcript is for display only).

## 1. Problem (code at aba6829)
- **Navigation is simulation only.** `AmapRouteEngine.start` returns unless `mode == .emulator` ("GPS guidance needs
  the Navi SDK"), and `NavigationController.mode` is fixed to `.emulator`. After 开始导航 a fake car drives the route
  at 60 km/h; guidance, HUD distance and ETA follow the fake car, not the driver.
- **Two positions.** The route origin is the real fix only if it is usable at that moment; otherwise
  `DriveSettings.demoOrigin` (珠海市人民政府). While navigating, `SelfPosition` R1 draws the simulated car; whenever
  `phase != .navigating` or `geometry.car == nil` it draws the real fix. The marker can jump between the fake car and
  the real position, and the fake car can be kilometres away.
- **Started without being asked.** Guidance starts only through `choose_navigation_option` in
  `awaitingRouteSelection`, but nothing stops the model from chaining the route pick into the same turn as the
  destination pick, so a route can start without the driver saying anything about it.
- Logs of the failing drive were not captured (recorder stopped 11:48; the drive was later), so the exact sequence
  is unconfirmed; the three causes above are from the code.

## 2. User-facing behaviour
### 2.1 The switch
- 设置 → **导航方式**: **真实导航（默认）** / **模拟导航（演示 / 录屏）**. Stored in Defaults (`navigationMode`).
- With 位置来源 = **演示起点** the mode is **模拟导航**, and the switch is shown disabled with the note
  「演示起点只能模拟导航」 (a fake start only makes sense with a fake car; REC-003 keeps the real position off screen).
- The mode is read when guidance starts; changing it during a trip applies to the next trip. A voice command does
  not switch modes (OQ-NAVM-1).

### 2.2 真实导航 (default)
- **Start**: the route origin is the current usable fix (F-16 §3). With no usable fix, guidance does not start and
  no demo origin is used: she says 「还没有定位，暂时不能导航。」 and, if permission is denied, 「请在设置里打开定位。」
  (OQ-NAVM-2: no automatic fallback to simulation).
- **Position**: the marker is the driver's real GPS position (F-16b fresh/provisional styles, heading arrow from the
  fix's course). There is **no simulated car**. The camera follows the marker (F-16b follow rules, navigation span).
- **Progress**: each fix is matched to the route; the current step, distance to the next turn, remaining distance and
  ETA come from the matched point. Guidance texts (F-14) are spoken when the matched point enters a step, as today.
  HUD speed is the fix's speed.
- **Off route**: when the fix is > 50 m from the route for 3 consecutive fixes spanning ≥ 5 s (and accuracy ≤ 50 m),
  she says 「已偏离路线，正在重新规划。」 and the route is recalculated from the current fix to the same destination
  (one recalculation per 15 s at most). The new route replaces the old one without a route choice.
- **Arrival**: within 30 m of the destination (or remaining ≤ 30 m on the matched route) → `arrived` (F-15).
- **GPS lost** (no fresh fix for 10 s): the marker turns provisional, progress holds (no instruction advances); after
  30 s without a fix she says once 「定位信号弱，导航暂停更新。」; the first fresh fix resumes.
- **Background**: location is When-In-Use only (F-16a §5); guidance continues only while the app is in the
  foreground (OQ-NAVM-3).

### 2.3 模拟导航
- Behaviour of today's simulation, kept: a fake car drives the chosen route at `speedKmh` (60), guidance and HUD follow
  it.
- **Start**: with 位置来源 = 手机位置 the fake car starts at the current usable fix; with no usable fix it starts at the
  demo origin and the HUD says so. With 演示起点 it always starts at the demo origin.
- **One marker**: the fake car is 我的位置 for the whole trip (F-16b OQ-MAP-2 rule); the real fix is not drawn. When the
  trip ends the marker returns to the real fix (or the demo dot).
- **Label**: the HUD shows **「模拟导航」** for the whole trip, and her start sentence says 「开始模拟导航」, so a
  simulation is never mistaken for guidance.

### 2.4 Never two positions
In both modes exactly **one** 我的位置 marker is on the map at any time. In 真实导航 it is never the simulated car;
in 模拟导航 it is the fake car from 开始 to the end of the trip, including the moments between engine updates.

### 2.5 Navigation only when asked
**Revised 2026-10-29** (owner, after device run 9f48c45, where 「最快的」 was refused three times with `WORDS_UNCLEAR` /
`NAVIGATION_NOT_REQUESTED`: "abandon the transcript that serve the tool calling, and the transcript only use for
display the text on the screen"). The first version of this section checked the driver's transcript against a word
list; that made a bad transcript veto a correct tool call. It is replaced by:
- **Gemini's tool call is the decision.** Gemini hears the audio and fills the arguments (`index`, `preference`,
  `name`); the app never reads the driver's transcript to allow or refuse a call (F-05a §6).
- `choose_navigation_option` that would **start guidance** (phase `awaitingRouteSelection`) runs when the situation
  allows it — list on screen, not stale, no start in flight (F-15, unchanged) — **and** the call comes in a later
  driver turn than the one in which the route list appeared. A **driver turn** is one utterance closed by the uplink
  gate (F-04a `activityEnd`); it is counted from audio boundaries, never from text. A call in the same driver turn
  as the list (the model chaining "pick destination → pick route" without the driver speaking again) is refused with
  `.navigationNotRequested`; she says 「有\(n)条路线，要走哪一条？」. Taps are never refused (I-6).
- `navigate_to` has no start guard: it only lists places and routes, nothing starts.
- **A refusal is never followed by a success claim.** While guidance is not running, a reply that claims a route was
  chosen or guidance started (已选/已经为你选/已开始导航/开始导航了) is held by the action-claim guard (F-09
  `ActionClaimGuard`, applied to her own reply text, not the driver's), and she says the refusal sentence instead.

## 3. Preconditions
- `NSLocationWhenInUseUsageDescription` (present). Amap Web key (present) for route calculation and recalculation.
- No Amap Navi SDK: real-mode progress, off-route and arrival are computed in the app from GPS fixes and the Amap Web
  route polyline (OQ-NAVM-4).

## 4. Inputs and outputs
- `NaviMode` (`gps` / `emulator`, NovaPorts) is now chosen per trip: `NavigationController` reads it from a
  `NavigationModeSetting` (pure: `mode(setting, source) -> NaviMode`, 演示起点 → `.emulator`).
- `AmapRouteEngine` gains the `.gps` path: it subscribes to `LocationUpdates` (F-16b T-044b) for the trip, feeds each
  fix to `RouteProgress`, and emits the same `NaviEngineEvent`s as the emulator path (`guidanceText`, `naviInfo`,
  `arrived`) plus `rerouting` / `rerouted`. `RouteGeometry.car` stays **nil** in `.gps` mode.
- **New pure model** (NovaNav/Flow): `RouteProgress` — input: route polyline + steps, fix (GCJ-02, accuracy, speed,
  time); output: matched point, distance along route, step index, distance to next step, remaining m / s, `onRoute`,
  `offRouteConfirmed`, `arrived`, `signalLost`. Tuned by `RouteProgressTuning` (50 m, 3 fixes / 5 s, 30 m, 10 s, 30 s,
  15 s).
- `SelfPosition.Input` gains `mode: NaviMode`; rule R1 (simulated car) applies only when `mode == .emulator`.
- New tool error code: `navigationNotRequested`, with one honest advice sentence in `ToolFailureAdvice`.
  (`wordsUnclear` is withdrawn, 2026-10-29.)
- `GuardContext` carries `driverTurn` (count of closed utterances, from the uplink gate) and `routeListTurn` (the
  `driverTurn` when the route list appeared); no transcript field is read by this guard.

## 5. State transitions
Unchanged F-15 phases, plus inside `navigating` (gps mode): `onRoute ⇄ offRoute(counting) → rerouting → onRoute`,
and `signalLost` as an overlay that freezes progress. `rerouting` keeps `phase == .navigating` (the HUD shows
「重新规划中」); a failed recalculation keeps the old route and retries after 15 s.

## 6. Events and triggers
Location fix, 15 s reroute limiter, 10 s / 30 s signal timers, route recalculation result, 导航方式 / 位置来源 change
(applies next trip), `choose_navigation_option` / `navigate_to` calls (guards).

## 7. Dependencies and external services
- Amap Web driving directions (existing) for start and recalculation. No Navi SDK.
- `RouteProgress`, `NavigationModeSetting`, guards and tests are pure Swift in NovaCore (Linux gates). CoreLocation
  stays in NovaPlatform; the engine consumes `LocationUpdates` only.

## 8. Error handling and recovery
| Case | Behaviour |
|---|---|
| 真实导航, no usable fix at start | no start; honest sentence; no demo origin |
| Permission denied at start | no start; 「请在设置里打开定位」 |
| Accuracy > 50 m | fix used for the marker, not for off-route counting |
| Recalculation fails (network, key) | keep the old route, say once 「重新规划失败，继续按原路线」; retry after 15 s |
| GPS lost mid-trip | §2.2: freeze, one sentence after 30 s, resume on the next fix |
| App to background (真实导航) | location paused (F-16a §5); on return progress jumps to the new matched point |
| Start/pick not asked | `.navigationNotRequested`, nothing starts |
- I-8: no coordinate, address or transcript in logs; diagnostics carry mode, on/off-route state, step index and
  counts only.

## 9. Concurrency, cancellation, timeouts
- The gps-path fix stream belongs to the trip (generation-tagged like the emulator task); `stop`, a new route or a
  newer generation cancels it; a late fix of an old generation is dropped.
- At most one recalculation in flight; a fix that arrives during it is still matched against the old route.
- Fix → marker and progress update ≤ 1 s.

## 10. Acceptance criteria (iOS)
| # | Criterion | Level |
|---|---|---|
| 1 | `NavigationModeSetting`: default `.gps`; 模拟导航 → `.emulator`; 演示起点 → `.emulator` whatever the switch says | unit |
| 2 | `RouteProgress`: matching, step entry, distance to next turn, remaining; off-route after 3 fixes ≥ 5 s > 50 m; accuracy > 50 m not counted; arrival 30 m; signal lost 10 s | unit |
| 3 | `SelfPosition`: in `.gps` mode never the simulated car; in `.emulator` mode the car for the whole trip; one marker in every phase | unit |
| 4 | Start guard (revised): a pick in a later driver turn than the list starts guidance whatever the transcript says (empty, Portuguese, unrelated text); a pick in the same driver turn as the list → `navigationNotRequested`; taps always allowed; `navigate_to` never refused by this guard; a success claim after a refusal is held | unit |
| 5 | Engine `.gps` path with a scripted fix stream: guidance texts in order, rerouting once per 15 s, `geometry.car == nil`, old-generation fixes dropped | unit (NovaServices) |
| 6 | 真实导航 on the road (≥ 2 km, ≥ 3 turns): the marker is the real position, the map follows it, turn instructions come before each turn, no second marker | D |
| 7 | Leaving the route on purpose: 「已偏离路线，正在重新规划」 within 10 s, a new route from the current position | D |
| 8 | 模拟导航: fake car drives, HUD shows 「模拟导航」, one marker, back to the real dot after 算了 | S, D |
| 9 | 演示起点: switch disabled with the note; simulation from the demo origin; no real position on screen (recording) | S, D |
| 10 | Asking for a destination does not also start a route in the same turn; she lists the routes and waits | D |
| 11 | No coordinate in logs during rows 6–7 | D |
| 12 | With the route list on screen, 「最快的」 / 「第二条」 / 「开始导航」 start guidance on the first try, even when the subtitle shows （没听清） or wrong text | D |

## 11. Implementation constraints
- Test names carry `F-15a` for the spec-trace gate.
- Pure parts in Packages/NovaCore (NovaNav/Flow, NovaNav/Presentation, NovaTools/Dispatch); the `.gps` engine path in
  Packages/NovaServices (AmapRouteEngine); 设置 row, HUD label and `SelfPosition` mode input in the App target.
- App changes need an iOS build (Codemagic, started only when the owner asks; no macOS GitHub runners, owner rule
  2026-10-27). Device rows stay NOT_VERIFIED until a phone run; rows 6–7 need a real drive.

## Open questions
- OQ-NAVM-1 **decided 2026-10-29 (owner: defaults): no**. Switch mode by voice (「模拟导航去机场」)? Default no: the setting only, so a misheard
  word cannot start the wrong mode.
- OQ-NAVM-2 **decided 2026-10-29: refuse**. 真实导航 with no usable fix: refuse with an honest sentence (default), or fall back to
  模拟导航 with a spoken notice?
- OQ-NAVM-3 **decided 2026-10-29: foreground only**. Keep guiding in the background? Needs Always/background location and a
  new permission text; out of scope by default.
- OQ-NAVM-4 **decided 2026-10-29: web route + own matching**. Use the Amap Navi SDK for real guidance instead (better matching,
  lane info, server reroute) — larger vendor integration, separate spec if wanted.

## Tasks (implementation-plan.md M3 follow-up, specs/work.json)
| ID | Task | Verification |
|---|---|---|
| T-040a | `NavigationModeSetting`, `RouteProgress` + tuning, `SelfPosition` mode input; rows 1–3 | unit (Linux gates) |
| T-040b | Guards `navigationNotRequested` (start / `navigate_to`) and `wordsUnclear`; advice sentences; row 4 | unit (Linux gates) |
| T-040c | `AmapRouteEngine` `.gps` path (LocationUpdates, progress events, reroute, generation); row 5 | unit (Linux gates) |
| T-040d | 设置 导航方式, 演示起点 lock, HUD 「模拟导航」 / 「重新规划中」, mode read at start; rows 6–11 | S, D |
| T-040e | Revised §2.5: start guard on driver turns (uplink gate count), no transcript; drop the `navigate_to` word guard and `wordsUnclear`; claim guard holds a success claim after a refusal; row 4 (revised), row 12 | unit (Linux gates), D |
