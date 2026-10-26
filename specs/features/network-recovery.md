# F-24 Network recovery

**Android status:** IMPLEMENTED (JVM; fault injection `NetworkFaults.dropConnectionNow`).
**Depends on:** contracts/voice-agent.md §8

## 1. Purpose
Survive brief network loss without losing the conversation.

## 2. User-facing behaviour
UI shows PROCESSING while reconnecting; conversation resumes with context.

## 3. Preconditions
A session that reached LISTENING at least once (with a resumption handle when the server gave one).

## 4. Inputs and outputs
- In: socket close / error with a code.
- Out: UI state RECONNECTING (chip PROCESSING, amber) then LISTENING, or ERROR with the code on the chip.

## 5. State transitions
LISTENING/THINKING/SPEAKING → RECONNECTING → LISTENING (resumed with the handle), or → ERROR after 5 failed
attempts. Terminal errors go straight to ERROR (contracts/voice-agent.md §8).

## 6. Events and triggers
WebSocket close/failure, setup timeout, server goAway; optional `NWPathMonitor` path change (PROPOSED).

## 7. Dependencies and external services
Gemini Live WebSocket (F-05).

## 8. Error handling and recovery
- Retryable: DISCONNECT, CONNECTION, DNS, TIMEOUT, WS_FAILED, TLS_FAILED, UNAVAILABLE, RESUME_UNAVAILABLE.
- Terminal: auth, credential, quota/rate, malformed/invalid model (e.g. close 1007 MALFORMED).
- Reply audio of the dropped turn is flushed (epoch); a tool already executed is not repeated.
- RESUME_UNAVAILABLE → a new session without the handle; she does not claim to remember the lost turn.

## 9. Concurrency, cancellation, timeouts
5 attempts, 200 ms initial, doubling, 8 s cap. A second error from the same dying socket joins the
reconnect in flight. Setup must complete within 10 s per attempt.

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
