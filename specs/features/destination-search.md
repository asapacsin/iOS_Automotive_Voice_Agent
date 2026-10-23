# F-16 Destination search and saved places

**Android status:** IMPLEMENTED (JVM + LIVE Amap Web). P53, P68 open.
**Depends on:** contracts/navigation.md, contracts/api-contracts.md (Amap Web)

## 1. Purpose
Turn a spoken place into up to 5 candidates near the driver, or along the route; answer 家/公司 from saved places.

## 2. User-facing behaviour
附近的加油站 sorts by distance; 珠海站 by weight; 家 uses the saved slot or says it is not set.

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
- Keyword stripping and verbatim retry produce the same queries as Android (unit, table-driven).
- 家乐福 is never treated as 家.
- Unset home → `HOME_NOT_SET`, no POI search.
- Coordinates converted to GCJ-02 before Amap calls; saved places are not converted.

## 11. Existing Android tests
`T/nav/LiveDestinationCandidateSourceTest`, `DestinationQueryTest`, `AlongRouteCorridorTest`, `SavedPlacesTest`, `InitialLocationRecenterTest`.

## 12. Source references (Android)
`A/nav/LiveDestinationCandidateSource.kt`; `A/AmapPoiClient.kt:89-92,219-256`; `A/nav/AlongRouteCorridor.kt:89-96`; `A/nav/SavedPlaces.kt:13-30`; `A/nav/SavedPlaceStore.kt:14`; `A/nav/amap/AmapCoordinates.kt`; `A/CoarseLocationProvider.kt:31-37`; `A/nav/InitialLocationRecenter.kt:120-126`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
Amap Web REST is plain HTTPS (A). Location: `CLLocationManager`, convert WGS-84 → GCJ-02 (PROPOSED). Recenter thresholds: fresh 30 s, provisional 10 min, accuracy ≤2000 m.
