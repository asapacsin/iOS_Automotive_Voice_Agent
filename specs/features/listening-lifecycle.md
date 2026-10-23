# F-02 Listening lifecycle and local phrases

**Android status:** ACTIVE (JVM-tested; EMU).
**Depends on:** contracts/voice-agent.md §2

## 1. Purpose
Keep the assistant listening while useful, go quiet on request, sleep after inactivity, and release the connection after long idle.

## 2. User-facing behaviour
- 「闭嘴」: she stops talking but keeps listening (SILENT_WAIT); next real command resumes.
- 「休眠」/「停止监听」 or the model's `end_conversation`: she sleeps.
- 30 s with nothing to do: sleep. 5 min asleep: disconnect (kept while navigating).

## 3. Preconditions
A session exists.

## 4. Inputs and outputs
In: utterance transcripts, busy/idle signals, wake/UI events, navigation phase. Out: upload on/off, speak on/off, connect/disconnect.

## 5. State transitions
See contracts/voice-agent.md §2 table.

## 6. Events and triggers
Local intent (`ListeningIntent`): SHUT_UP, GO_TO_SLEEP, PASS_TO_MODEL; whole utterance only; 「算了/取消」 never intercepted; cancel-like phrases go to the model while a picker is open or a task pending.

## 7. Dependencies and external services
None external.

## 8. Error handling and recovery
Deadlines passing while busy fire 1.5 s after becoming idle.

## 9. Concurrency, cancellation, timeouts
One timer job guarded by an epoch and a lock; timers paused while busy; VAD noise does not extend them.

## 10. Acceptance criteria (iOS)
- Given ACTIVE and idle, when 30 s pass with no speech, then SLEEP and no audio is uploaded.
- Given SLEEP and navigating, when 5 min pass, then the connection stays open.
- Given ACTIVE, when the driver says 「闭嘴」, then current speech stops, state SILENT_WAIT, and no tool call is made.
- Given a picker is open, when the driver says 「算了」, then it reaches the model (not intercepted).

## 11. Existing Android tests
`T/voice/ListeningLifecycleTest`, `ListeningIntentTest`, `SilentWaitIntegrationTest`.

## 12. Source references (Android)
`A/voice/ListeningLifecycle.kt:16-24,57-60,105`; `A/voice/ListeningIntent.kt:21`; `A/AndroidToolDispatcher.kt:376`.

## 13. Implementation constraints
Pure logic; port as a deterministic Swift state machine with an injected clock.

## iOS notes (PROPOSED unless labelled)
Directly portable (class A). Use an injected clock for tests.
