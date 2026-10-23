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
Guard order (first wins): unsupportedMedia → sunroofOnWindowTool → nearbyQuestionWhileNavigating → vagueExitWhileNavigating → speechOutputNotRequested → ambiguousReferent → repeatedInTurn; plus driverSideWindow rewrite, savedPlaceMissing, withPowerAdvice. Failure wording from `ToolFailureAdvice`.

## 9. Concurrency, cancellation, timeouts
Dispatcher waits: navigation request 10 s, options 8 s.

## 10. Acceptance criteria (iOS)
- Each guard has a Given/When/Then unit test identical to the Android test cases (port the tables).
- Given 「打开天窗」, then `UNSUPPORTED_BODY_PART` and no window moves.

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
