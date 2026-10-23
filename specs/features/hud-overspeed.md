# F-17 Navigation HUD and overspeed alert

**Android status:** IMPLEMENTED (JVM + EMU). Overspeed not observable on US CI runners (limitKmh=0).
**Depends on:** contracts/navigation.md

## 1. Purpose
Show the next manoeuvre, distance, road, remaining distance/time, speed limit; warn on overspeed.

## 2. User-facing behaviour
Turn arrow + 「300米 进入 东风路」, 「剩余 8.6 km」, 「限速 60」; voice 「您已超速，限速60公里」.

## 3. Preconditions
See depends-on contracts.

## 4. Inputs and outputs
See contracts/navigation.md.

## 5. State transitions
See contracts.

## 6. Events and triggers
Tool call or UI event.

## 7. Dependencies and external services
See contracts/api-contracts.md.

## 8. Error handling and recovery
Errors are ok=false results with codes; see refs.

## 9. Concurrency, cancellation, timeouts
See contracts.

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
