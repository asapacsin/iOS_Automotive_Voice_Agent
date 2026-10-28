# F-16b Show the driver's current position on the map (我的位置)

**Status:** DRAFT (owner request 2026-10-28: "on the map there is no current location showing up, write a spec
to solve this problem"). iOS only. Extends [F-16a Use the phone's real location](current-location.md) and
[F-25 Main screen](ui-overlay.md). Defaults below are the recommended answers; OQ-MAP-1..3 stay open until the
owner decides.
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
- **我的位置 marker**: a blue dot with a white ring at the current position, whenever a usable fix exists
  (F-16 §3: age ≤ 10 min, accuracy ≤ 2000 m).
  - Fresh fix (≤ 30 s): solid blue dot. When accuracy > 30 m, a translucent blue circle of that radius around it.
  - Provisional fix (30 s – 10 min): the same dot in gray ("last known position").
  - No usable fix (none yet, too old, too coarse, permission denied): no dot. No dot is ever drawn at a guessed place.
- **演示起点 source**: the dot is drawn at the demo origin with the caption **演示位置**, so a recording never shows a
  private place (REC-003) and a viewer is not misled (F-16a §2).
- **Initial recenter**: on the first usable fix after the drive screen appears (or after switching 位置来源), the map
  moves once to the dot at a ~1.5 km span, unless the driver already panned or zoomed the map, or a place list or
  route choice is on screen (those keep their own framing, T-044).
- **Follow while idle** (default, OQ-MAP-1): while no list, route choice or navigation is shown, the map keeps the dot
  in view as it moves. A driver's pan or zoom stops following.
- **回到我的位置 button** (`location.fill`, bottom-right above the car card, accessibility id `locate-me`): recenters on
  the dot and resumes following. With no usable fix it shows `location.slash` and, on tap, either asks permission
  (not asked yet), opens 设置 (denied, `UIApplication.openSettingsURLString`), or does nothing but stays visible
  (waiting for the first fix).
- **While navigating** (default, OQ-MAP-2): navigation is simulated (F-15), so the simulated car marker
  (`location.north.circle.fill`) is the one that moves along the route and the camera follows it, as today. The
  我的位置 dot stays drawn but smaller and gray, so the real position is never hidden and is never confused with
  the simulated car.
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
  `{ visible: Bool, coordinate: GeoCoordinate (GCJ-02), style: fresh|provisional|demo|navigatingSecondary,
     accuracyRadius_m: Double?, caption: "演示位置"? }`.
- **Datum**: the dot uses the **same datum as routes and markers**: `CoordinateConverter.gcj02(fix)` (no-op outside
  China), so the dot lies on the drawn road in mainland China. MapKit's own `UserAnnotation` is **not** used: it would
  plot a second, independently shifted position and could disagree with the route line and the demo source.
- **Camera policy** (pure, `MapCameraPolicy`): inputs = SelfPosition, `MapPresentation`, `userMovedMap`, `firstFixShown`;
  output = `.none | .center(GeoCoordinate, spanMeters: 1500) | .fitRoutes | .followCar`. Throttle: re-center only
  when the dot moved ≥ 10 m or ≥ 1 s passed, so the camera does not jitter.

## 5. State transitions
`noFix → fresh ⇄ provisional → noFix` (by age/accuracy, re-evaluated every 5 s and on each fix).
Camera: `awaitingFirstFix → following` (first fix, recenter once) `→ free` (driver pans) `→ following` (locate-me).
List, route choice or navigation override following while shown; when they close, the camera returns to
`following` only if it was following before.
Scene background → updates paused (F-16a §5); foreground → resumed, the dot shows provisional until a new fix.

## 6. Events and triggers
Location fix, permission change, 位置来源 switch, scene phase, navigation phase change, map pan/zoom gesture,
locate-me tap, 5 s re-evaluation timer.

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
| 2 | Walking/driving 100 m moves the dot and the map follows; a pan stops following; locate-me resumes it | D |
| 3 | `SelfPosition`: fresh/provisional/none by age and accuracy (30 s, 10 min, 2000 m), accuracy circle only > 30 m, demo style + caption | unit |
| 4 | `MapCameraPolicy`: first fix recenters once; no recenter after a pan; list/route choice/navigation override; 10 m / 1 s throttle | unit |
| 5 | The dot uses GCJ-02 like the route line: in mainland China it sits on the road the route is drawn on | unit (converter) + D |
| 6 | 演示起点: dot at the demo origin with 演示位置; no real position visible (screen recording) | S, D |
| 7 | Denied: no dot, 定位未开启 pill opens the app's settings page | S, D |
| 8 | Navigating: simulated car marker moves and is followed; the real dot stays visible as gray secondary | S, D |
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
- OQ-MAP-1 (default: **follow while idle**): should the map keep following the dot when idle, or only recenter once?
  Recommendation: follow, stopped by a pan; this matches a car display.
- OQ-MAP-2 (default: **car leads, real dot gray**): during simulated navigation, show both markers? Recommendation: yes,
  the real one secondary, so a simulated drive never hides the real position.
- OQ-MAP-3 (default: **no heading arrow**): rotate the dot with `CLLocation.course`? Recommendation: not now; course
  is unreliable at low speed.

## Tasks (implementation-plan.md M3, specs/work.json)
| ID | Task | Verification |
|---|---|---|
| T-044a | `SelfPosition` + `MapCameraPolicy` (pure, NovaNav/Presentation) + `LocationUpdates` port; unit tests F-16b rows 3–5 | unit (Linux gates) |
| T-044b | `CoreLocationProvider`/`DemoLocation`/`SwitchableLocationProvider` updates stream; fake-manager test | unit, build (Mac) |
| T-044c | `DriveView`: dot, accuracy circle, locate-me button, 定位未开启 pill, follow/free camera; rows 1–2, 6–9 | S, D |
