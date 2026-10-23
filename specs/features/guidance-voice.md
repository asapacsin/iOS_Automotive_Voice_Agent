# F-14 Navigation guidance voice (relay)

**Android status:** IMPLEMENTED (JVM; EMU with real Gemini). P46 open: assistant-spoken guidance gives up after the first prompt in some runs.
**Depends on:** contracts/navigation.md, F-08

## 1. Purpose
Speak turn-by-turn prompts in 小诺's voice when possible, else Amap's own voice, never overlapping.

## 2. User-facing behaviour
Prompts like 「前方300米右转」 are spoken once, in her voice or Amap's.

## 3. Preconditions
Navigating; relay preference on (`nova_guidance_relay/assistant_speaks_guidance`).

## 4. Inputs and outputs
In: Amap guidance text. Out: verbatim prompt to the session (prefix 「请一字不改地朗读…」) or Amap TTS.

## 5. State transitions
Relay item: QUEUED → PENDING → ASSISTANT, or routed to Amap with a reason (DISABLED, EXPIRED, NOT_CONNECTED, NO_CAPABILITY, DRIVER_SPEAKING, RESPONSE_OPEN, WORK_PENDING, AMAP_SPEAKING, FOCUS, COOLDOWN, FIDELITY_STRIKES, SEND_FAILED, DEADLINE).

## 6. Events and triggers
Amap `onGetNavigationText`, speaking start/end.

## 7. Dependencies and external services
Amap Navi SDK; session (F-05).

## 8. Error handling and recovery
Deadline fallback; 2 consecutive → 60 s cooldown; fidelity strikes ≥2 → Amap for the rest of the trip; echo of a relayed sentence within 10 s dropped once.

## 9. Concurrency, cancellation, timeouts
One prompt at a time, FIFO; deadline 1200 ms from enqueue; bracket 300 ms/char min 1500 ms.

## 10. Acceptance criteria (iOS)
- Every guidance sentence is spoken exactly once (assistant or Amap), never both, never overlapping a reply.
- Given the session is disconnected, guidance falls back to Amap immediately.

## 11. Existing Android tests
`T/nav/GuidanceRelayTest`, `GuidanceFidelityTest`, `T/nav/amap/AmapGuidanceVoiceTest`, `NavigationVoiceOutputTest`, `GuidancePromptTrackerTest`.

## 12. Source references (Android)
`A/nav/GuidanceRelay.kt:41-53,97-109,261-300,349-354`; `A/nav/amap/AmapGuidanceVoice.kt:137,157,166,214-221`; `A/voice/VoiceSessionGateway.kt:248-256`.

## 13. Implementation constraints
3000 ms deadline is only a debug override (UNVERIFIED as default).

## iOS notes (PROPOSED unless labelled)
Amap iOS exposes the guidance text in `driveManager:playNaviSoundString:soundStringType:` with `driveManagerIsNaviSoundPlaying:`, and its built-in voice is off by default (`isUseInternalTTS = NO`), so the relay ports directly (VERIFIED, OQ-IOS-2).
