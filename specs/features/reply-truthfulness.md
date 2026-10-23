# F-06 Reply pipeline and truthfulness gates

**Android status:** ACTIVE (JVM + LIVE suites).
**Depends on:** contracts/voice-agent.md §6

## 1. Purpose
Never let her claim an action that did not happen; hold, correct or drop such replies.

## 2. User-facing behaviour
She says 「空调开了」 only after the climate tool returned ok; if the tool failed she says why.

## 3. Preconditions
Session running.

## 4. Inputs and outputs
In: reply text/audio, tool results. Out: judged SpeechText clauses, corrections sent to the model.

## 5. State transitions
Turn: open → (held) → released or voided → closed.

## 6. Events and triggers
Tool result ok/false, generationComplete, turnComplete, new driver turn.

## 7. Dependencies and external services
None.

## 8. Error handling and recovery
One corrective nudge per utterance; correction grace 20 s (tool may follow) / 1.5 s (chat).

## 9. Concurrency, cancellation, timeouts
Hold budget 120 events; correction cancelled by a tool call or new driver turn.

## 10. Acceptance criteria (iOS)
- Given the model says 「好的，空调已打开」 with no tool call, then the line is not spoken and a correction is sent.
- Given `control_climate` returns ok=false, then no success claim is heard.
- Given 「导航已开始」 before NAVIGATING, then it is corrected (`NAVIGATION_NOT_STARTED`).

## 11. Existing Android tests
`T/voice/ActionClaimGuardTest`, `GeminiCorrectionGraceTest`, `PhantomTurnGateTest`, `PhantomTurnSuppressionTest`, `EmptyResponseRetryPolicyTest`, `NoAnswerReaskGeminiTest`, `DriverTurn*Test`.

## 12. Source references (Android)
`A/voice/DriverTurnPipeline.kt:395`; `A/voice/ActionClaimGuard.kt:447,671,850,855`; `A/voice/GeminiCorrectionGrace.kt`; `A/voice/EmptyResponseRetryPolicy.kt:259-261`; `A/voice/PhantomTurnGate.kt:94-146`.

## 13. Implementation constraints
Invariants I-1, I-5, I-11, I-14 are product rules.

## iOS notes (PROPOSED unless labelled)
Pure logic: portable (A).
