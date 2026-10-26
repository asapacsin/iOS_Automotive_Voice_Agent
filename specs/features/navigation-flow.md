# F-15 Navigation flow (search → pick → route → navigate → cancel)

**Android status:** IMPLEMENTED (JVM + EMU, Amap Navi SDK 11.2.100).
**Depends on:** contracts/navigation.md, contracts/api-contracts.md (Amap)

## 1. Purpose
Take the driver from a spoken destination to running guidance with voice selection, and cancel cleanly.

## 2. User-facing behaviour
导航去珠海站 → 「找到5个地点，请说第几个」 → 第一个 → 「有3条路线…说开始导航」 → 开始导航 → 导航已开始; 算了 cancels a list; 结束导航 stops guidance.

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
- Phase transitions match contracts/navigation.md for scripted SDK fakes (unit).
- A stale SDK callback after cancel changes nothing (unit).
- After 算了 the route line is not drawn (simulator UI test).
- 开始导航 starts exactly one navigation (no double start).

## 11. Existing Android tests
`T/nav/EmbeddedNavigationControllerTest`, `EmbeddedNavigationCancelInFlightTest`, `NavigationCancelledReplyTest`, `NavigationPendingChoiceTest`, `NavigationChoiceResolverTest`, `NavigationPickerInterceptTest`, `NavigationLocalPickGuardTest`, `NavigationPhaseTest`, `NavigationStateStoreTest`, `nav/amap/MapPresentationPolicyTest`.

## 12. Source references (Android)
`A/nav/EmbeddedNavigationController.kt:74-124,126,155,219,312,330,351,416,462,492,535-537`; `A/nav/NavigationPhase.kt:8-20`; `A/nav/amap/AmapNaviViewHost.kt:109,459-554,610-660`; `A/nav/amap/MapPresentationPolicy.kt:29-31`; `A/nav/NavigationChoice.kt`; `A/nav/NavigationPickerIntercept.kt:83-93`; `A/nav/NavigationLocalPickGuard.kt`.

## 13. Implementation constraints
`PhaseOneNavigationController` and `NavigationAutoPick` are not wired in main (DEAD); do not port.

## iOS notes (PROPOSED unless labelled)
Amap iOS Navi SDK (`AMapNaviDriveManager`, `AMapNaviDriveView`) — multi-route calculation (`AMapNaviDrivingStrategyMultipleDefault`, `naviRoutes`), `startGPSNavi` / `startEmulatorNavi` VERIFIED in Amap docs; the route-select call name is confirmed in M3 (OQ-IOS-2). Keep the controller as pure Swift over a `NaviEngine` protocol; the SDK lives only in the adapter (I-9).

## iOS: proper navigation vs the current build (PROPOSED, 2026-10-26)
**Current build (`feat/live-agent-nav`):** routes come from Amap Web driving directions and the car moves
along the chosen route by **simulation** (`NovaServices/AmapWeb/AmapRouteEngine.swift`,
`simulated_movement=true`). There is no Amap Navi SDK yet, so there is no real GPS following, no SDK
turn-by-turn guidance, no off-route reroute and no real arrival. The demo may use this mode, but it must
be labelled simulated in the UI and the evidence sheet and must never be presented as real navigation (I-1).

**Proper navigation (done when all hold):**
- Guidance runs from the phone's real position (`AMapNaviDriveManager` `startGPSNavi`, T-043); the
  simulated engine stays only for tests and indoor demos behind the same `NaviEngine` port.
- The HUD shows the live turn, step distance, next road, remaining distance/time and speed limit from
  SDK updates (contracts/navigation.md HUD fields), not from the static route.
- Turn-by-turn guidance is voiced through the guidance lane (F-14), arbitrated against replies (F-08).
- Leaving the route triggers an SDK reroute; the new route replaces the line without a new pick, and
  the reply does not claim a reroute that the SDK did not report.
- `NAVIGATING → ARRIVED` comes from the SDK arrival callback, then guidance stops and the route line goes.
- Screen lock / background during navigation keeps guidance running (T-064, F-23).

**Acceptance (iOS, added):**
- With a scripted engine, a reroute callback replaces the drawn route and keeps the phase NAVIGATING (unit).
- Arrival callback → ARRIVED, guidance stopped, no route drawn (unit, S).
- Real drive of at least 2 km with one deliberate wrong turn: guidance voiced, reroute, arrival (D).
