# F-07 Assistant voice (Azure TTS) and playback

**Android status:** ACTIVE when an Azure voice is configured (ADR-016).
**Depends on:** contracts/audio.md, contracts/api-contracts.md (Azure)

## 1. Purpose
Speak judged reply text in one consistent Chinese voice with low latency, in clause order.

## 2. User-facing behaviour
She starts speaking quickly; the subtitle matches what she says; if TTS fails the subtitle still shows.

## 3. Preconditions
Azure key; reply passed the truthfulness gate.

## 4. Inputs and outputs
In: SpeechText clauses. Out: 24 kHz PCM to the player.

## 5. State transitions
Per reply: clauses queued → synthesising (≤2 in flight) → playing → done/cancelled.

## 6. Events and triggers
Interrupted, Error, Closed, VOIDED, cancelCurrentReply cancel the reply.

## 7. Dependencies and external services
Azure Speech REST.

## 8. Error handling and recovery
No fallback to Gemini audio on Azure failure; subtitle still shown.

## 9. Concurrency, cancellation, timeouts
Clause deadline 4000 + 400 ms × chars; warm-up every 15 s; playback epochs.

## 10. Acceptance criteria (iOS)
- Given a 3-clause reply, then clauses play in order with no gap >100 ms when warm (measure on device).
- Given barge-in during clause 2, then clause 3 never plays.
- Given Azure returns 401, then the subtitle shows and no Gemini audio plays.

## 11. Existing Android tests
`T/voice/AssistantVoiceRevoicerTest`, `AssistantVoiceRevoicerWaitCueTest`, `AzureSpeechVoiceTest`, `ClauseSegmenterTest`, `LowLatencyPlaybackBufferTest`, `PlaybackEpochEngineTest`, `WaitCuesTest`.

## 12. Source references (Android)
`A/voice/AssistantVoiceRevoicer.kt:26-55`; `A/voice/AzureSpeechVoice.kt:70,177,187-188`; `A/voice/PcmAudioPlayer.kt:121-136,631,684-767,820`; `A/voice/WaitCues.kt:33-39`.

## 13. Implementation constraints
Epoch-based flush is required for instant interruption.

## iOS notes (PROPOSED unless labelled)
`AVAudioPlayerNode` scheduling buffers; `AVSpeechSynthesizer` is NOT a substitute for parity (different voice) — PROPOSED.
