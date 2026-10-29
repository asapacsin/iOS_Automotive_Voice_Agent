# F-16 Destination search and saved places

**Android status:** IMPLEMENTED (JVM + LIVE Amap Web). P53, P68 open.
**Depends on:** contracts/navigation.md, contracts/api-contracts.md (Amap Web)

## 1. Purpose
Turn a spoken place into up to 5 candidates near the driver, or along the route; answer 家/公司 from saved places.

## 2. User-facing behaviour
附近的加油站 sorts by distance; 珠海站 by weight; 家 uses the saved slot or says it is not set.

## 3. Preconditions
- Amap Web key saved (`AMAP_WEB_KEY_MISSING` otherwise).
- Location permission for nearby and along-route search; a fix counts as fresh for 30 s, provisional up
  to 10 min, accuracy ≤ 2000 m. Without a usable fix, text search (no city) is used.
- 家/公司 need the saved slot (`save_place`); otherwise `HOME_NOT_SET` / `WORK_NOT_SET` and no search.

## 4. Inputs and outputs
- In: the `navigate_to` destination string, or `query_live_info(kind=along_route)` while navigating.
- Query building: strip filler and navigation verbs (导航去, 带我去, 附近的); if the stripped query finds
  nothing, retry once with the verbatim text.
- Out: up to 5 `Place` {name, address, coordinate (GCJ-02), distance m when known}, ordered by distance for
  nearby/category queries (附近的加油站) and by Amap weight for named places (珠海站).
- Saved places return a single place without a POI search.

## 5. State transitions
Stateless per query; the resulting list enters F-15 (AWAITING_DESTINATION_SELECTION or route calculation).

## 6. Events and triggers
`navigate_to` (F-15), `query_live_info` along_route, `save_place`, first location fix (initial map recenter).

## 7. Dependencies and external services
Amap Web REST `/v3/place/text`, `/v3/place/around` (radius 50 000 m, ≤ 5 results);
CoreLocation (`CLLocationManager`), `CoordinateConverter` WGS-84 → GCJ-02; saved places in local storage
(already GCJ-02, not converted again).

## 8. Error handling and recovery
| Case | Code |
|---|---|
| Key missing / rejected (Amap infocode 10001 etc.) | `AMAP_WEB_KEY_MISSING` |
| Quota exceeded | `LIVE_INFO_QUOTA` |
| Network / non-OK response | `LIVE_INFO_UNAVAILABLE` |
| 0 results after verbatim retry | `NO_CANDIDATES` |
| Home / work not saved | `HOME_NOT_SET` / `WORK_NOT_SET` |
| Blank / too long destination | `BLANK_DESTINATION` / `DESTINATION_TOO_LONG` (validation) |
Keys and coordinates are never logged in full (I-8).

## 9. Concurrency, cancellation, timeouts
HTTP timeout per request follows the shared Amap Web client; a newer `navigate_to` makes older results
stale (F-15 generation). Along-route search while navigating keeps the current guidance; 0 results or
cancel restore it.

## 10. Acceptance criteria (iOS)
- Keyword stripping and verbatim retry produce the same queries as Android (unit, table-driven).
- 家乐福 is never treated as 家.
- Unset home → `HOME_NOT_SET`, no POI search.
- Coordinates converted to GCJ-02 before Amap calls; saved places are not converted.
- `save_place` claims success only when the slot reads back the found place, else `PLACE_NOT_SAVED`
  (unit, PROPOSED iOS row, I-1).

## 11. Existing Android tests
`T/nav/LiveDestinationCandidateSourceTest`, `DestinationQueryTest`, `AlongRouteCorridorTest`, `SavedPlacesTest`, `InitialLocationRecenterTest`.

## 12. Source references (Android)
`A/nav/LiveDestinationCandidateSource.kt`; `A/AmapPoiClient.kt:89-92,219-256`; `A/nav/AlongRouteCorridor.kt:89-96`; `A/nav/SavedPlaces.kt:13-30`; `A/nav/SavedPlaceStore.kt:14`; `A/nav/amap/AmapCoordinates.kt`; `A/CoarseLocationProvider.kt:31-37`; `A/nav/InitialLocationRecenter.kt:120-126`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
Amap Web REST is plain HTTPS (A). Location: `CLLocationManager`, convert WGS-84 → GCJ-02 (PROPOSED). Recenter thresholds: fresh 30 s, provisional 10 min, accuracy ≤2000 m.
