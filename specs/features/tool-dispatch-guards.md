# F-09 Tool catalog, dispatch and guards

**Android status:** ACTIVE (JVM + LIVE).
**Depends on:** contracts/voice-agent.md §6, contracts/navigation.md

## 1. Purpose
Expose the product tools to the model and refuse unsafe or unrequested calls deterministically.

## 2. User-facing behaviour
She does what was asked; for unsupported or unsafe requests she says one honest sentence.

## 3. Preconditions
Session running.

## 4. Inputs and outputs
Tools (see table in feature-inventory.md). Args ≤4096 bytes; call ids ≤128 chars `[A-Za-z0-9_-]`; invalid args → `_validation_error`.

## 5. State transitions
Stateless per call except repeat-in-turn tracking.

## 6. Events and triggers
toolCall from the provider; local picks.

## 7. Dependencies and external services
All executors.

## 8. Error handling and recovery
Guard order (first wins), iOS after F-05a §6 (2026-10-29, T-016d, T-016e): validate → navigationNotRequested (F-15a,
driver turns) → repeatedInTurn → savedPlaceMissing; plus withPowerAdvice. (confirmExit was added by T-016d and removed
by T-016e: 结束导航 ends at once, no confirmation.) No guard reads the driver's transcript. **Superseded** (they read
the transcript): unsupportedMedia, sunroofOnWindowTool, nearbyQuestionWhileNavigating (now: navigate_to while guiding
lists over the route), vagueExitWhileNavigating (now: no guard), speechOutputNotRequested, ambiguousReferent, driverSideWindow rewrite. Android order, for reference:
unsupportedMedia → sunroofOnWindowTool → nearbyQuestionWhileNavigating → vagueExitWhileNavigating →
speechOutputNotRequested → ambiguousReferent → repeatedInTurn. Failure wording from `ToolFailureAdvice`.

## 9. Concurrency, cancellation, timeouts
Dispatcher waits: navigation request 10 s, options 8 s.

## 10. Acceptance criteria (iOS)
- Each guard has a Given/When/Then unit test identical to the Android test cases (port the tables). Superseded by
  F-05a §6 for the word-based guards (their tables were removed with them).
- ~~Given 「打开天窗」, then `UNSUPPORTED_BODY_PART` and no window moves.~~ Superseded (F-05a §6): no tool controls the
  sunroof; the model says it is unsupported.

## 11. Existing Android tests
`T/ToolCallGuard*Test`, `AndroidToolDispatcherTest`, `RealtimeToolCatalogTest`, `SavedPlaceGuardTest`.

## 12. Source references (Android)
`A/AndroidToolDispatcher.kt:159,229-235,336-337`; `A/ToolCallGuards.kt`; `A/tools/ToolRegistry.kt:42-55`; `A/ToolFailureAdvice.kt`.

## 13. Implementation constraints
Guards are code, not prompt (I-11).

## iOS notes (PROPOSED unless labelled)
Portable (A). Keep tool names and argument schemas identical so the same system prompt works.

## Evidence (EVIDENCE_REQUEST batch 1, answered 2026-10-23 from Android commit 9c53929)
- Catalog: names, descriptions and parameter schemas of all 17 tools from `A/tools/*Domain.kt`, in
  `ToolRegistry.PRODUCT` domain order, with `repeatSensitive` flags. iOS: generated into
  `Core/NovaTools/Dispatch/ToolCatalog+Generated.swift` (descriptions extracted verbatim).
- Validation codes per domain (`INVALID_FIELDS`, `INVALID_FIELD_TYPE`, …), `UNKNOWN_TOOL`, and
  `ARGUMENTS_TOO_LARGE` (`GeminiLiveProtocol.kt:266`, > 4096 bytes).
- `A/ToolCallGuards.kt` (all guards, regexes and word lists), `A/ToolFailureAdvice.kt` (42 codes +
  `CONFIRM_CALL`, `CHOOSE_CONTACT`, `CLIMATE_OFF`), `AndroidToolDispatcher.guard` order.
- Guard test tables from `T/ToolCallGuard*Test.kt` are ported in `Tests/NovaToolsTests/ToolCallGuardTests.swift`.
- `ambiguousReferent` needs F-10 `ContextResolver` (T-030); the dispatcher takes it as a `clarify` closure.
