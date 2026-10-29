# F-16b.1 Map position logic (T-044a)

**Status:** APPROVED 2026-10-29 (derived from [F-16b](map-current-location.md), all OQ-MAP decided by the owner).
iOS only. The pure-Swift half of F-16b: **which marker the map shows, where, in which style, and what the camera
does**. No MapKit, CoreLocation or UIKit here; the screen (T-044c) only draws what these types return.
**Depends on:** F-16b §2, §4, §5, §10; F-16 §3 fix rules (`LocationQuality`); contracts/navigation.md
(`NavigationPhase`).
**Owned paths:** `Packages/NovaCore/Sources/NovaNav/Presentation/` (new `SelfPosition.swift`,
`MapCameraPolicy.swift`), `Packages/NovaCore/Sources/NovaPorts/Navigation.swift` (fields on `LocationFix`, new
`LocationUpdates`), `Packages/NovaCore/Sources/NovaKit/Tuning.swift` (new `MapPositionTuning`), tests in
`Packages/NovaCore/Tests/NovaNavTests/`.
**Gates:** `scripts/gates/run_all.sh` (Linux Swift 6.0.3 is enough: everything here builds and runs off-device).

## 1. Tuning (`MapPositionTuning`, NovaKit)
| Name | Value | Why |
|---|---|---|
| `headingMinSpeed` | 5 km/h (1.389 m/s) | below it `CLLocation.course` is noise (OQ-MAP-3) |
| `accuracyCircleMin` | 30 m | smaller circles hide under the marker |
| `followMinMove` | 10 m | camera does not jitter on GPS noise |
| `followMinInterval` | 1 s | at most one camera move per second |
| `autoRecenterAfter` | 15 s | in-car convention: back to the car after no touch (OQ-MAP-1) |
| `followSpanMeters` | 1500 m | F-16b §2 initial and follow span |
| `reevaluateEvery` | 5 s | fresh → provisional → gone without a new fix |
| `simulatedHeadingMinStep` | 1 m | bearing between two simulated car points shorter than this is ignored |
Freshness and accuracy limits are **not** duplicated: they come from `LocationQuality.of` (`AmapWebTuning`:
fresh 30 s, provisional 10 min, accuracy ≤ 2000 m).

## 2. Port changes (NovaPorts)
- `LocationFix` gains `speedMetersPerSecond: Double?` and `courseDegrees: Double?` (nil = unknown; CoreLocation's
  negative "invalid" values are mapped to nil by the adapter). Both default to nil in `init`, so existing callers
  and tests compile unchanged.
- New `public protocol LocationUpdates: Sendable { func updates() -> AsyncStream<LocationFix> }`. Only declared here;
  the implementations are T-044b.

## 3. `SelfPosition` (NovaNav/Presentation)
```swift
public struct SelfPosition: Sendable, Hashable {
    public enum Style: Sendable, Hashable { case fresh, provisional, demo, simulated }
    public enum Hidden: Sendable, Hashable { case notDetermined, denied, noFix, unusable }
    public let marker: Marker?      // nil = draw nothing
    public let hidden: Hidden?      // set exactly when marker is nil
    public struct Marker: Sendable, Hashable {
        public let coordinate: GeoCoordinate   // always .gcj02 (same datum as routes and markers)
        public let style: Style
        public let headingDegrees: Double?     // nil = dot, set = arrow; 0 = north, clockwise
        public let accuracyRadiusMeters: Double?
        public let caption: String?            // "演示位置" for the demo source, else nil
    }
    public static func make(_ input: Input, tuning: MapPositionTuning = .init()) -> SelfPosition
}
public struct Input {
    fix: LocationFix?, source: LocationSource, permission: LocationAuthorization, now: NovaInstant,
    phase: NavigationPhase, simulatedCar: GeoCoordinate?, simulatedHeadingDegrees: Double?
}
```
Rules, **first match wins**:
| # | Condition | Result |
|---|---|---|
| R1 | `phase == .navigating` and `simulatedCar != nil` | marker at `simulatedCar`, style `.simulated`, heading = `simulatedHeadingDegrees`, no circle; caption 演示位置 if `source == .demo` (OQ-MAP-2: one marker) |
| R2 | `source == .demo` | marker at the demo fix (already GCJ-02), style `.demo`, no heading, no circle, caption 演示位置 |
| R3 | `permission == .notDetermined` | hidden `.notDetermined` |
| R4 | `permission == .denied` | hidden `.denied` |
| R5 | `fix == nil` | hidden `.noFix` |
| R6 | `LocationQuality.of(fix, at: now) == nil` (too old or too coarse) | hidden `.unusable` |
| R7 | quality `.fresh` | marker, style `.fresh` |
| R8 | quality `.provisional` | marker, style `.provisional` |
For R7/R8:
- coordinate = `CoordinateConverter.gcj02(fix.coordinate)` when the datum is `.wgs84`, else unchanged.
- heading = `courseDegrees` only when style is `.fresh`, `speedMetersPerSecond ≥ headingMinSpeed` and
  `0 ≤ courseDegrees < 360`; otherwise nil (a provisional fix never shows an arrow: it is not moving now).
- accuracy circle = `horizontalAccuracyMeters` when `> accuracyCircleMin`, else nil.

Simulated heading helper: `SelfPosition.bearing(from: GeoCoordinate, to: GeoCoordinate) -> Double?`, initial
great-circle bearing in degrees `[0, 360)`; nil when the two points are closer than `simulatedHeadingMinStep`. The
caller keeps the previous `RouteGeometry.car` and the last non-nil bearing, so a stop on the route keeps the arrow.

**Locate-me button** derived from `SelfPosition` and the camera mode (§4):
| State | Icon | Tap action |
|---|---|---|
| marker, camera `.following` | `location.fill` | none (already following) |
| marker, camera `.free` / `.awaitingFirstFix` | `location` | `.recenter` |
| hidden `.notDetermined` | `location.slash` | `.askPermission` |
| hidden `.denied` | `location.slash` | `.openSettings` (+ 定位未开启 pill shown) |
| hidden `.noFix` / `.unusable` | `location.slash` | none (waiting) |
`public enum LocateAction { case none, recenter, askPermission, openSettings }`.

## 4. `MapCameraPolicy` (NovaNav/Presentation)
A value type; the view feeds it events and applies the command it returns. It never reads a clock itself.
```swift
public struct MapCameraPolicy: Sendable {
    public enum Mode: Sendable, Hashable { case awaitingFirstFix, following, free(lastTouch: NovaInstant) }
    public enum Framing: Sendable, Hashable { case open, lists, navigating }
    public enum Command: Sendable, Hashable { case center(GeoCoordinate, spanMeters: Double), fitContent }
    public enum Event: Sendable, Hashable {
        case position(SelfPosition, at: NovaInstant)
        case framing(Framing, at: NovaInstant)
        case userGesture(at: NovaInstant)      // only gestures the driver made, not programmatic moves
        case locateMe(at: NovaInstant)
        case tick(at: NovaInstant)             // every reevaluateEvery, and at lastTouch + autoRecenterAfter
        case sourceChanged
    }
    public private(set) var mode: Mode = .awaitingFirstFix
    public mutating func handle(_ event: Event) -> Command?
}
```
`Framing` comes from `MapPresentation` (T-044): `.lists` when a place list or route choice is shown (`list != nil`),
`.navigating` when `followCar`, else `.open`.

Rules:
| # | Event | Rule |
|---|---|---|
| C1 | `framing(.lists)` | return `.fitContent` once on entering; while `.lists`, positions and ticks return nil; `mode` is kept for later |
| C2 | `framing(.open)` or `.navigating` from `.lists` | if `mode == .following` and a marker is known → `.center(marker)`; else nil |
| C3 | `position` with no marker | nil, mode unchanged |
| C4 | `position`, mode `.awaitingFirstFix`, framing not `.lists` | `.center(marker, followSpanMeters)`, mode → `.following` |
| C5 | `position`, mode `.following`, framing not `.lists` | `.center` only if moved ≥ `followMinMove` from the last centered point **and** ≥ `followMinInterval` since the last center; else nil |
| C6 | `position`, mode `.free` | nil (the driver is looking elsewhere) |
| C7 | `userGesture(at: t)` | mode → `.free(lastTouch: t)` (also from `.awaitingFirstFix`: a driver who already moved the map is not yanked to the first fix); nil |
| C8 | `tick(at: t)`, mode `.free(lastTouch)`, `t − lastTouch ≥ autoRecenterAfter`, framing not `.lists`, marker known | `.center(marker)`, mode → `.following` |
| C9 | `locateMe(at:)` with a marker | `.center(marker)` at once (no throttle), mode → `.following` |
| C10 | `locateMe` with no marker | nil (the view runs the §3 `LocateAction` instead) |
| C11 | `sourceChanged` | mode → `.awaitingFirstFix`; last centered point forgotten |
In `.navigating` framing the marker is the simulated car (R1), so C4/C5/C8/C9 follow the car with the same
throttle and the same 15 s return after a pan.

## 5. Concurrency
Both types are synchronous values with no I/O; the drive screen owns one `MapCameraPolicy` on the main actor.
`SelfPosition.make` is recomputed on every fix, permission change, navigation snapshot, geometry update and tick.

## 6. Logging (I-8)
Nothing here logs. If a diagnostic is added later it carries only `Style`/`Hidden`/`Mode` names, never a coordinate.

## 7. Tests (NovaNavTests, names carry `F-16b` for spec-trace)
| Test | Covers |
|---|---|
| `F-16b SelfPosition: fresh/provisional/none by age and accuracy (30 s, 10 min, 2000 m)` | R5–R8, row 3 |
| `F-16b SelfPosition: denied and not asked hide the marker with their reason` | R3, R4, locate table |
| `F-16b SelfPosition: accuracy circle only above 30 m` | R7, row 3 |
| `F-16b SelfPosition: demo source draws 演示位置 at the demo point, no arrow, no circle` | R2, row 3 |
| `F-16b SelfPosition: arrow only when fresh, ≥ 5 km/h and a valid course` (4.9 vs 5.0 km/h, course −1, 360, provisional) | row 4a |
| `F-16b SelfPosition: a WGS-84 fix in China is drawn in GCJ-02; outside China unchanged` | row 5 |
| `F-16b SelfPosition: navigating draws one simulated marker with the route bearing; back to the real fix after` | R1, row 8 |
| `F-16b bearing: north 0, east 90, under 1 m nil` | helper |
| `F-16b MapCameraPolicy: first fix recenters once at 1500 m; a gesture before it prevents that` | C4, C7, row 4 |
| `F-16b MapCameraPolicy: following throttles at 10 m and 1 s` | C5, row 4 |
| `F-16b MapCameraPolicy: pan stops following; 15 s untouched recenters; 14.9 s does not` | C6–C8, row 4 |
| `F-16b MapCameraPolicy: locate-me recenters at once without throttle` | C9, C10 |
| `F-16b MapCameraPolicy: lists fit once and freeze; closing them resumes following only if it was following` | C1, C2, row 4 |
| `F-16b MapCameraPolicy: source switch waits for the next first fix` | C11 |
On PASS, add `T-044a: F-16b` to `specs/trace-ids.txt`.

## 8. Out of scope (other tasks)
- Yielding fixes and filling speed/course from `CLLocation` (T-044b, NovaPlatform).
- Drawing, gestures, `onMapCameraChange`, the pill and the button (T-044c, App target, Mac build + device).
