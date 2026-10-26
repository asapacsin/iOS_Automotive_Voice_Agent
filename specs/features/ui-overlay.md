# F-25 Main screen, assistant overlay and choice overlay

**Android status:** IMPLEMENTED (JVM for models; EMU screenshots).
**Depends on:** contracts/voice-agent.md §1, contracts/navigation.md

## 1. Purpose
Full-screen map with a small assistant bubble (latest exchange only), a status chip, a navigation choice list, and on-screen affordances.

## 2. User-facing behaviour
Bubble shows 你: … / 小诺: …, fades by itself; chip 聆听中 / PROCESSING (amber) / SPEAKING; choice overlay lists candidates/routes; tapping = same executor as voice (I-6).

## 3. Preconditions
None for the screen; a session for the bubble and chip; navigation for the list and HUD.

## 4. Inputs and outputs
- In: session UI state, latest user transcript and reply text, navigation snapshot (places, routes, phase,
  HUD), simulated car position.
- Out: status chip, bubble (你: … / 小诺: …, latest exchange only), choice list rows, map overlays,
  camera icon and preview window (F-20a). Accessibility identifiers (e.g. `status-chip`) for UI tests.

## 5. State transitions
Chip mapping (contracts/voice-agent.md §1): DISCONNECTED→IDLE; CONNECTING/RECONNECTING/THINKING→PROCESSING
(amber); LISTENING/USER_SPEAKING→聆听中; SPEAKING→SPEAKING; ERROR→ERROR (+ code). The list is visible while
the phase is awaitingDestinationSelection or awaitingRouteSelection; a route line is drawn only for offered
or chosen routes, never after cancel.

## 6. Events and triggers
Session state changes, transcripts, navigation snapshot publishes, taps (row, 开始/结束对话, camera).

## 7. Dependencies and external services
SwiftUI `DriveView` over the map (Amap map view later, T-044); `AgentRuntime` composition root.

## 8. Error handling and recovery
- The error chip shows the session error code so device runs can be diagnosed.
- A tap on a row calls the same executor as the voice choice (I-6) and gets the same codes (`OPTIONS_STALE`, …).

## 9. Concurrency, cancellation, timeouts
All view state updates on the main actor; the bubble fades on its own (`BubbleFadeTuning`, iOS values); a new
exchange replaces the bubble at once.

## 10. Acceptance criteria (iOS)
- Chip mapping identical (unit).
- A tap on a choice row calls the same executor as the voice choice (unit).
- Bubble holds 4 s + 120 ms per character (max 10 s), never while speaking, then fades over 500 ms; a
  new exchange replaces it at once (unit; iOS values, owner decision 2026-10-26, no Android parity).
- `open_app` maps/settings switches the screen and the reply comes from the screen read back; an
  unknown app is `APP_NOT_ALLOWED`; a switch that did not happen is `APP_NOT_OPENED`, never claimed (unit, PROPOSED iOS row).

## 11. Existing Android tests
`T/ui/AssistantUiStateMapperTest`, `TranscriptBubbleFadeTest`, `TranscriptBubbleSessionSimulationTest`, `RecentTranscriptTest`, `ShownErrorCardTest`, `AffordanceMatcherTest`, `ScreenAffordanceRunnerTest`.

## 12. Source references (Android)
`A/ui/AssistantNavigationScreen.kt`; `A/ui/AssistantOverlayView.kt:310,446`; `A/ui/AssistantUiStateMapper.kt:6-25`; `A/ui/NavigationChoiceOverlay.kt`; `A/NavigationChoiceAction.kt`; `A/ui/TranscriptBubbleFade.kt`; `A/ui/ScreenAffordances.kt`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
SwiftUI over the Amap map view (B).
