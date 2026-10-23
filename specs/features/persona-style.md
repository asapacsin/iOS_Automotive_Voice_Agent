# F-21 Persona and speaking style

**Android status:** IMPLEMENTED (JVM + LIVE 5/5).
**Depends on:** F-09

## 1. Purpose
Persona 小诺 with switchable tones that never stop her doing the task.

## 2. User-facing behaviour
说话嗲一点/傲娇一点/温柔一点/元气一点/正常一点 change tone; 霸道一点 is refused with the list of styles.

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
- Style persists across sessions.
- Instructions capped at 4000 chars.
- After a style change, an action request is still executed.

## 11. Existing Android tests
`T/PersonaProfilesTest`, `SpeakingStyleTest`, `SpeakingStyleStoreTest`, `tools/SpeakingStyleToolTest`.

## 12. Source references (Android)
`A/PersonaProfiles.kt:4-6,31,36-49`; `A/SpeakingStyle.kt:4`; `A/SpeakingStyleStore.kt:7`; `A/tools/SpeechDomain.kt:13`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
Portable (A); store in UserDefaults.
