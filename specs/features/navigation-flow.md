# F-15 Navigation flow (search → pick → route → navigate → cancel)

**Android status:** IMPLEMENTED (JVM + EMU, Amap Navi SDK 11.2.100).
**Depends on:** contracts/navigation.md, contracts/api-contracts.md (Amap)

## 1. Purpose
Take the driver from a spoken destination to running guidance with voice selection, and cancel cleanly.

## 2. User-facing behaviour
导航去珠海站 → 「找到5个地点，请说第几个」 → 第一个 → 「有3条路线…说开始导航」 → 开始导航 → 导航已开始; 算了 cancels a list; 结束导航 stops guidance.

## 3. Preconditions
- Amap Web key saved in 设置 (`AMAP_WEB_KEY`); missing or rejected → `AMAP_WEB_KEY_MISSING`.
- Location permission (When In Use) for "near me" search; without a fix, search falls back to text search.
- A running live session for the voice path; the choice list can also be tapped (F-25).

## 4. Inputs and outputs
- `navigate_to(destination ≤120 chars)` → `candidates_listed` {count, candidates[], next} for 2–5 places,
  or goes straight to route calculation for exactly one place.
- `choose_navigation_option` (exactly one of index / preference / name) → routes listed
  (AWAITING_ROUTE_SELECTION) or guidance started (NAVIGATING).
- `exit_navigation_mode()` → stopped guidance, closed list, or nothing active.
- Every result carries a `next` sentence that tells the model what to say (never read the list aloud).
- Published snapshot for the UI: phase, generation, places, routes, destination, live info, last guidance.

## 5. State transitions
As contracts/navigation.md. iOS phases (`NavigationPhase`): idle, resolvingDestination,
awaitingDestinationSelection, calculatingRoute, awaitingRouteSelection, navigating, arrived, error.
Each request or cancel calls `advance(to:)`, which raises the generation.

## 6. Events and triggers
Tool calls (`navigate_to`, `choose_navigation_option`, `exit_navigation_mode`); a tap on a list row;
the local picker intercept (ordinals, preferences, 开始导航); engine events (routesReady,
routeCalculationFailed, naviStarted, naviInfo, guidanceText, arrived, naviStopped, cameraInfo).

## 7. Dependencies and external services
`PlaceSearch` (Amap Web `/v3/place/around`, `/v3/place/text`), `LocationProvider` (CoreLocation,
WGS-84 → GCJ-02), `NaviEngine` port: `AmapRouteEngine` (Amap Web driving + simulated movement, current
build) and `AmapNaviEngine` (Navi SDK, T-043). Guidance voice through F-14.

## 8. Error handling and recovery
| Case | Code | What she says (from `next`/advice) |
|---|---|---|
| Key missing/rejected | `AMAP_WEB_KEY_MISSING` | the search service is not set up; says nothing was found |
| Network / HTTP failure | `LIVE_INFO_UNAVAILABLE` | search failed, asks to say it again |
| 0 places | `NO_CANDIDATES` | not found, asks for another wording |
| No route / calc failure | `ROUTE_CALCULATION_FAILED` | route could not be planned |
| Start did not confirm in 8 s | `START_FAILED` | navigation did not start; never claims it did (I-1) |
| Pick with no list / old list | `NO_OPTIONS_ON_SCREEN` / `OPTIONS_STALE` | see F-10 navigation ambiguity |
| Pick while still searching | `OPTIONS_NOT_READY` | asks to wait a moment |
Failures reset to idle; the map stops drawing any route.

## 9. Concurrency, cancellation, timeouts
- Route wait 10 s, start wait 8 s, choice lifetime 120 s, at most 5 candidates, search radius 50 km
  (`NavigationTuning`).
- A result or engine event with an older generation is dropped; a request that finishes after a newer
  one returns `OPTIONS_STALE` and changes nothing.
- A new destination while navigating stops the old guidance first.
- Duplicate model picks within 5 s of a local pick are suppressed; `开始导航` starts at most one navigation.

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
