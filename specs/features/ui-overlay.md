# F-25 Main screen, assistant overlay and choice overlay

**Android status:** IMPLEMENTED (JVM for models; EMU screenshots).
**Depends on:** contracts/voice-agent.md §1, contracts/navigation.md

## 1. Purpose
Full-screen map with a small assistant bubble (latest exchange only), a status chip, a navigation choice list, and on-screen affordances.

## 2. User-facing behaviour
Bubble shows 你: … / 小诺: …, fades by itself; chip 聆听中 / PROCESSING (amber) / SPEAKING; choice overlay lists candidates/routes; tapping = same executor as voice (I-6).

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
- Chip mapping identical (unit).
- A tap on a choice row calls the same executor as the voice choice (unit).
- Bubble fade timing identical to Android constants (unit).

## 11. Existing Android tests
`T/ui/AssistantUiStateMapperTest`, `TranscriptBubbleFadeTest`, `TranscriptBubbleSessionSimulationTest`, `RecentTranscriptTest`, `ShownErrorCardTest`, `AffordanceMatcherTest`, `ScreenAffordanceRunnerTest`.

## 12. Source references (Android)
`A/ui/AssistantNavigationScreen.kt`; `A/ui/AssistantOverlayView.kt:310,446`; `A/ui/AssistantUiStateMapper.kt:6-25`; `A/ui/NavigationChoiceOverlay.kt`; `A/NavigationChoiceAction.kt`; `A/ui/TranscriptBubbleFade.kt`; `A/ui/ScreenAffordances.kt`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
SwiftUI over the Amap map view (B).
