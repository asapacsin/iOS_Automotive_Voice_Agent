# F-24 Network recovery

**Android status:** IMPLEMENTED (JVM; fault injection `NetworkFaults.dropConnectionNow`).
**Depends on:** contracts/voice-agent.md §8

## 1. Purpose
Survive brief network loss without losing the conversation.

## 2. User-facing behaviour
UI shows PROCESSING while reconnecting; conversation resumes with context.

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
- Given a forced socket drop, reconnect within the policy and resume with the handle (integration test against a fake server).
- No app-level connectivity monitor exists on Android (UNVERIFIED); iOS may add `NWPathMonitor` as an improvement, not parity.

## 11. Existing Android tests
`T/voice/WorkReconnectDiagnosticsTest`, `VoiceSessionControllerTest`.

## 12. Source references (Android)
`I/ReconnectPolicy.kt:12`; `I/VoiceSessionController.kt:586-608`; `A/voice/NetworkFaults.kt:13`; `GeminiLiveProtocol.kt:313-324`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
`NWPathMonitor` optional (PROPOSED).
