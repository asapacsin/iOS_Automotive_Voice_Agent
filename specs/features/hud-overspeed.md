# F-17 Navigation HUD and overspeed alert

**Android status:** IMPLEMENTED (JVM + EMU). Overspeed not observable on US CI runners (limitKmh=0).
**Depends on:** contracts/navigation.md

## 1. Purpose
Show the next manoeuvre, distance, road, remaining distance/time, speed limit; warn on overspeed.

## 2. User-facing behaviour
Turn arrow + 「300米 进入 东风路」, 「剩余 8.6 km」, 「限速 60」; voice 「您已超速，限速60公里」.

## 3. Preconditions
Phase NAVIGATING (F-15). Before the first engine update the panel shows 「等待导航数据…」.

## 4. Inputs and outputs
- In: engine `naviInfo` (turn icon type 2–16, step distance m, next road, remaining distance m and time s)
  and `cameraInfo` (camera type, limit km/h, distance); facility speed limit; current speed.
- Out: panel model (title 导航中 → destination, turn word + arrow, step distance, 进入 {road},
  剩余 x.x km · duration, 限速 N km/h when N > 0, last guidance line); overspeed voice line
  「您已超速，限速{N}公里」.

## 5. State transitions
Panel: hidden → waiting (等待导航数据…) → live → hidden on STOPPED/ARRIVED/idle.
Overspeed: under → over (alert once) → under; a limit change while over re-arms the alert.

## 6. Events and triggers
Engine `naviInfo` and `cameraInfo` events (generation-checked, F-15); speed updates; phase changes.

## 7. Dependencies and external services
`NaviEngine` port: Amap Navi SDK `updateNaviInfo:` / `updateCameraInfos:` (T-043). The simulated
`AmapRouteEngine` produces turn and distance info from the static route but no camera limits.
Overspeed voice goes through the guidance lane and arbiter (F-14, F-08; T-053).

## 8. Error handling and recovery
- Limit 0 or missing = no data: no 限速 label, never an overspeed alert.
- Missing road name → the 进入 line is omitted, not invented.
- Stale events (older generation) are dropped.

## 9. Concurrency, cancellation, timeouts
Limit = nearest camera with limit > 0 merged with the facility limit. Alert on first exceedance or limit
change, min gap 10 000 ms. Panel updates are coalesced on the main actor; no timer of its own.

## 10. Acceptance criteria (iOS)
- Panel text identical to Android for the same navigation-info fixture (unit).
- Overspeed fires once per exceedance, min gap 10 s; limit 0 never alerts (unit).

## 11. Existing Android tests
`T/nav/TextNavigationPanelModelTest`, `nav/amap/OverspeedAlertTest`, `DrivingSpeedHudTest`, `EmulatorNaviSpeedTest`, `RouteCameraSummaryTest`, `NavigationProgressTraceTest`.

## 12. Source references (Android)
`A/nav/TextNavigationPanelModel.kt:56-87`; `A/nav/amap/DrivingSpeedHud.kt`; `A/nav/amap/OverspeedAlert.kt`; `A/nav/amap/AmapNaviViewHost.kt:121,786-806`; `A/nav/amap/EmulatorNaviSpeed.kt:11-13`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
Amap iOS gives `updateNaviInfo:` (road, remaining time/distance) and `updateCameraInfos:` (camera type, whether it limits speed, distance) (VERIFIED, OQ-IOS-2).
