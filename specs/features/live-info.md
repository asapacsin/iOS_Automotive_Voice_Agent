# F-18 Live info: weather, route traffic, along-route, place details

**Android status:** IMPLEMENTED (JVM + EMU live shards ≥9/10).
**Depends on:** contracts/api-contracts.md (Amap Web), F-09

## 1. Purpose
Answer 天气/还要多久/前面堵不堵/路上有没有加油站 from real data or refuse (I-3).

## 2. User-facing behaviour
「明天珠海天气…」; 「剩余8.6公里，前方1公里有拥堵」; never invented.

## 3. Preconditions
See depends-on contracts.

## 4. Inputs and outputs
See refs.

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
- route_traffic when not navigating → `NOT_NAVIGATING`.
- Timeout 4 s → honest failure, no invented answer.
- Explicit ETA field: UNVERIFIED (only remaining_km observed).

## 11. Existing Android tests
`T/LiveInfoToolTest`, `AmapLiveInfoParserTest`, `LiveInfoAlongRouteWiringTest`, `RouteLiveInfoMappingTest`.

## 12. Source references (Android)
`A/LiveInfoTool.kt:25-30,37,64,158,404-414`; `A/AmapLiveInfoParser.kt`; `A/tools/LiveInfoServer.kt`, `LiveInfoDomain.kt`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
Portable HTTP (A); route traffic needs the navigation engine's remaining distance and traffic status.
