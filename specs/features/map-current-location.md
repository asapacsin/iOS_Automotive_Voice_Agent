# F-16b Show the driver's current position on the map (我的位置)

**Status:** APPROVED 2026-10-29 (OQ-MAP-1..3 decided by the owner) (owner request 2026-10-28: "on the map there is no current location showing up, write a spec
to solve this problem"). iOS only. Extends [F-16a Use the phone's real location](current-location.md) and
[F-25 Main screen](ui-overlay.md). Defaults below are the recommended answers; OQ-MAP-1..3 stay open until the
owner decides. Owner decision 2026-10-29: follow in-car map conventions (CarPlay, Android Auto, 高德
car mode), not phone-map ones: OQ-MAP-1 and OQ-MAP-3 are decided below.
**Depends on:** F-16a (T-042a `CoreLocationProvider`, `SwitchableLocationProvider`), F-16 §3 fix rules,
F-15 (simulated car during navigation), F-25 (T-044 `MapPresentationPolicy`), contracts/api-contracts.md

## 1. Problem (owner report 2026-10-28; code at c65aa7a)
- `DriveView.map` draws only `model.geometry.car`, the **simulated car** that `AmapRouteEngine.onGeometry`
  publishes while a route runs. Outside navigation `geometry.car` is nil, so the map shows **no position at all**,
  even with 手机定位 allowed and a fresh fix.
- The map camera starts on `DriveSettings.demoOrigin` (珠海市人民政府) and never moves to the phone's position:
  F-16a §2 ("the map recenters on the first fix") and F-16 §6 (first fix → initial recenter) are not implemented.
- The location provider is pull-only (`latestFix()`); nothing pushes new fixes to the screen.
- F-16a OQ-LOC-2 assumed "the map already follows the position"; it does not. This feature closes that gap.

## 2. User-facing behaviour
- **我的位置 marker** at the current position, whenever a usable fix exists (F-16 §3: age ≤ 10 min,
  accuracy ≤ 2000 m). In-car style: while moving (speed ≥ 5 km/h from `CLLocation.speed`, course valid) it is a
  **heading arrow** pointing along `CLLocation.course`; when stopped, slower, or with no valid course it is a
  blue dot with a white ring, so the arrow never points a wrong way at low speed.
  - Fresh fix (≤ 30 s): solid blue dot. When accuracy > 30 m, a translucent blue circle of that radius around it.
  - Provisional fix (30 s – 10 min): the same dot in gray ("last known position").
  - No usable fix (none yet, too old, too coarse, permission denied): no dot. No dot is ever drawn at a guessed place.
- **演示起点 source**: the dot is drawn at the demo origin with the caption **演示位置**, so a recording never shows a
  private place (REC-003) and a viewer is not misled (F-16a §2).
- **Initial recenter**: on the first usable fix after the drive screen appears (or after switching 位置来源), the map
  moves once to the dot at a ~1.5 km span, unless the driver already panned or zoomed the map, or a place list or
  route choice is on screen (those keep their own framing, T-044).
- **Follow while idle** (OQ-MAP-1, decided 2026-10-29): while no list, route choice or navigation is shown, the map
  keeps the marker centered as the car moves, like a car display. A driver's pan or zoom stops following and shows
  回到我的位置; after **15 s without touching the map** it snaps back and follows again (in-car auto-recenter).
- **回到我的位置 button** (`location.fill`, bottom-right above the car card, accessibility id `locate-me`): recenters on
  the dot and resumes following. With no usable fix it shows `location.slash` and, on tap, either asks permission
  (not asked yet), opens 设置 (denied, `UIApplication.openSettingsURLString`), or does nothing but stays visible
  (waiting for the first fix).
- **While navigating** (OQ-MAP-2, decided 2026-10-29: "for simulation the two should be the same"): there is
  **one** position marker. The simulated drive starts at the real position (route origin = the current usable fix,
  F-16 §3; demo origin only with 演示起点 or no usable fix), and while it runs the simulated car *is* 我的位置: the
  same marker style (heading arrow from the route bearing) moves along the route and the camera follows it. The real
  fix is not drawn separately. When navigation ends (arrived, 算了, exit) the marker returns to the real fix.
- Permission denied: a small pill on the map **定位未开启** (tap → 打开系统设置); no dot.

## 3. Preconditions
- `NSLocationWhenInUseUsageDescription` (already set). When In Use only, no background location (F-16a §5).
- No new key: the dot needs no Amap Web call.

## 4. Inputs and outputs
- Input: the selected source's fixes (`LocationFix`, WGS-84 from CoreLocation; demo fix for 演示起点) and the
  permission state.
- **New port** (NovaPorts): `LocationUpdates { func updates() -> AsyncStream<LocationFix> }`, implemented by
  `CoreLocationProvider` (yields every delegate fix) and `DemoLocation` (one fix), forwarded by
  `SwitchableLocationProvider` for the current source (a source switch ends the old stream's use and starts the new).
- **New pure model** (NovaNav/Presentation): `SelfPosition` computed from (latest fix, source, permission, now,
  navigation phase):
  `{ visible: Bool, coordinate: GeoCoordinate (GCJ-02), style: fresh|provisional|demo|simulated,
     heading: Double? (degrees, set only when speed ≥ 5 km/h and course ≥ 0), accuracyRadius_m: Double?,
     caption: "演示位置"? }`. `LocationFix` gains optional `speedMetersPerSecond` and `courseDegrees`.
- **Datum**: the dot uses the **same datum as routes and markers**: `CoordinateConverter.gcj02(fix)` (no-op outside
  China), so the dot lies on the drawn road in mainland China. MapKit's own `UserAnnotation` is **not** used: it would
  plot a second, independently shifted position and could disagree with the route line and the demo source.
- **Camera policy** (pure, `MapCameraPolicy`): inputs = SelfPosition, `MapPresentation`, `userMovedMap` (with the time of
  the last touch), `firstFixShown`, now;
  output = `.none | .center(GeoCoordinate, spanMeters: 1500) | .fitRoutes | .followCar`. Throttle: re-center only
  when the dot moved ≥ 10 m or ≥ 1 s passed, so the camera does not jitter.

## 5. State transitions
`noFix → fresh ⇄ provisional → noFix` (by age/accuracy, re-evaluated every 5 s and on each fix).
Camera: `awaitingFirstFix → following` (first fix, recenter once) `→ free` (driver pans) `→ following` (locate-me, or 15 s after the last touch).
List, route choice or navigation override following while shown; when they close, the camera returns to
`following` only if it was following before.
Scene background → updates paused (F-16a §5); foreground → resumed, the dot shows provisional until a new fix.

## 6. Events and triggers
Location fix, permission change, 位置来源 switch, scene phase, navigation phase change, map pan/zoom gesture,
locate-me tap, 15 s auto-recenter timer (restarted by each touch), 5 s re-evaluation timer.

## 7. Dependencies and external services
- CoreLocation stays in NovaPlatform/Location (I-9); MapKit only in the App target. `SelfPosition` and
  `MapCameraPolicy` are pure Swift in NovaNav with tests on Linux.
- No network service.

## 8. Error handling and recovery
| Case | Map shows |
|---|---|
| Permission not asked | no dot; locate-me asks permission |
| Denied / restricted | no dot; pill 定位未开启 → 打开系统设置 |
| No fix yet (first ≤ 3 s, F-16a §4) | no dot; camera stays where it is |
| Fix older than 10 min or accuracy > 2000 m | no dot (never a stale guess) |
| Source 演示起点 | demo dot + 演示位置 |
No coordinate or address is logged (I-8); diagnostics carry only the style (`fresh`, `provisional`, `none`).

## 9. Concurrency, cancellation, timeouts
The updates stream is consumed on the main actor by the drive screen only while it is visible; the task ends
when the screen disappears. Fix → dot latency ≤ 1 s. No polling of `latestFix()` from the view.

## 10. Acceptance criteria (iOS)
| # | Criterion | Level |
|---|---|---|
| 1 | 手机定位 allowed, not navigating: the blue dot appears at the phone's position within 3 s of opening the app, and the map recenters on it once | D |
| 2 | Driving 100 m moves the marker and the map follows; a pan stops following; locate-me resumes it, and so does 15 s without touching | D |
| 3 | `SelfPosition`: fresh/provisional/none by age and accuracy (30 s, 10 min, 2000 m), accuracy circle only > 30 m, demo style + caption | unit |
| 4 | `MapCameraPolicy`: first fix recenters once; following stops on a pan and resumes after 15 s idle or locate-me; list/route choice/navigation override; 10 m / 1 s throttle | unit |
| 4a | `SelfPosition` heading: arrow only at speed ≥ 5 km/h with a valid course; dot otherwise | unit |
| 5 | The dot uses GCJ-02 like the route line: in mainland China it sits on the road the route is drawn on | unit (converter) + D |
| 6 | 演示起点: dot at the demo origin with 演示位置; no real position visible (screen recording) | S, D |
| 7 | Denied: no dot, 定位未开启 pill opens the app's settings page | S, D |
| 8 | Navigating: one marker; it starts at the real position, moves along the route and is followed; no second dot; after navigation ends it is back at the real fix | unit (SelfPosition), S, D |
| 9 | No coordinate in logs while the dot moves (log capture during row 2) | D |

## 11. Implementation constraints
- `SelfPosition`, `MapCameraPolicy` and the new tests go in Packages/NovaCore (NovaNav/Presentation); test names carry
  `F-16b` for the spec-trace gate.
- `LocationUpdates` in NovaPorts; `CoreLocationProvider` and `DemoLocation` implement it; `SwitchableLocationProvider`
  forwards it. No MapKit/CoreLocation import in NovaCore.
- `DriveView` draws the dot with `Annotation` + `MapCircle`, reads the gesture via `onMapCameraChange` (user-initiated
  changes set `userMovedMap`), and keeps the existing car marker for navigation.
- App target changes need a Mac/SDK build; per the owner rule of 2026-10-27, no macOS CI run unless the owner asks.
  Device rows stay NOT_VERIFIED until a phone run.

## Open questions
- OQ-MAP-1 **decided 2026-10-29 (owner: in-car conventions)**: follow while idle; a pan stops it; auto-recenter after
  15 s untouched or on locate-me.
- OQ-MAP-2 **decided 2026-10-29 (owner)**: one marker during simulated navigation; the simulated car starts at the real
  position and stands for it until navigation ends.
- OQ-MAP-3 **decided 2026-10-29 (owner: in-car conventions)**: heading arrow from `CLLocation.course` while moving
  (≥ 5 km/h), dot when stopped.

## Tasks (implementation-plan.md M3, specs/work.json)
| ID | Task | Verification |
|---|---|---|
| T-044a | `SelfPosition` + `MapCameraPolicy` (pure, NovaNav/Presentation) + `LocationUpdates` port, detailed in [map-logic.md](map-logic.md); unit tests F-16b rows 3–5, 4a | unit (Linux gates) |
| T-044b | `CoreLocationProvider`/`DemoLocation`/`SwitchableLocationProvider` updates stream; fake-manager test | unit, build (Mac) |
| T-044c | `DriveView`: dot, accuracy circle, locate-me button, 定位未开启 pill, follow/free camera; rows 1–2, 6–9 | S, D |
