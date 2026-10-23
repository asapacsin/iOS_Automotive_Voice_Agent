# F-05 Realtime session (Gemini Live)

**Android status:** ACTIVE provider. Qwen frozen, Baidu dormant.
**Depends on:** contracts/voice-agent.md, contracts/api-contracts.md (Gemini)

## 1. Purpose
Hold one realtime conversation with Gemini Live: stream audio up, receive transcripts, tool calls and reply.

## 2. User-facing behaviour
Natural back-and-forth; reconnects silently after a network blip.

## 3. Preconditions
Gemini API key, consent accepted, network.

## 4. Inputs and outputs
See api-contracts.md Gemini section.

## 5. State transitions
contracts/voice-agent.md §1 and §4.

## 6. Events and triggers
setupComplete, serverContent, toolCall, toolCallCancellation, goAway, sessionResumptionUpdate, interrupted.

## 7. Dependencies and external services
Gemini Live API.

## 8. Error handling and recovery
contracts/voice-agent.md §8; resumption handle kept in memory, cleared on disconnect; 1007/1008 handling.

## 9. Concurrency, cancellation, timeouts
Events serialised; WebSocket reader thread owns turn state; event buffer 1024.

## 10. Acceptance criteria (iOS)
- Contract tests replay recorded Gemini server messages and assert the emitted event order of §4.
- Given a socket drop mid-turn, when reconnecting with a handle, then the conversation continues and the UI shows PROCESSING, not ERROR.
- Given an auth error, then no retry and a config message is shown.

## 11. Existing Android tests
`T/voice/GeminiLiveClientTest`, `GeminiLiveProtocolTest`, `GeminiLiveProviderVoiceTest`, `GeminiTurnTimingTest`, `GeminiTurnDiagnosticsTest`, `RealtimeProviderFactoryTest`, `VoiceSessionControllerTest`, `VoiceSessionStateMachineTest`, `RealtimeProviderContractTest`.

## 12. Source references (Android)
`A/voice/GeminiLiveClient.kt:46,59,128,170,454-502,607-632`; `GeminiLiveProtocol.kt:40-83,188-251,313-342`; `I/VoiceSessionController.kt:356,385-475,586-608`; `I/ReconnectPolicy.kt`; `A/GeminiSettings.kt` (`QWEN_FROZEN`).

## 13. Implementation constraints
Keep the provider-neutral contract (I-13); the iOS app must not depend on Gemini types outside the adapter.

## iOS notes (PROPOSED unless labelled)
`URLSessionWebSocketTask` (PROPOSED); verify ping/keepalive and 10 s setup timeout. Background socket lifetime limited by iOS (see ios-feasibility).
