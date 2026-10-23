# F-12 Comfort scenarios

**Android status:** IMPLEMENTED (JVM + LIVE text).
**Depends on:** F-11

## 1. Purpose
Multi-step responses to situations: mosquito, mosquito done, mosquito still there, stuffy, drowsy.

## 2. User-facing behaviour
有蚊子 → windows half open; 蚊子还没走 → AC on, fan +1 (windows untouched); 蚊子出去了 → close; 有点闷 → AC on, fan +1, front windows 20; 好困 → AC on, temp −2, front windows 20, music play, suggests a rest stop.

## 3. Preconditions
None.

## 4. Inputs and outputs
`run_scenario{name ∈ mosquito, mosquito_done, stuffy, drowsy}`; partial completion reports `partial`.

## 5. State transitions
Steps executed in order.

## 6. Events and triggers
Tool call.

## 7. Dependencies and external services
F-11, F-13 (music).

## 8. Error handling and recovery
Partial result is reported honestly (ActionClaimGuard).

## 9. Concurrency, cancellation, timeouts
Sequential.

## 10. Acceptance criteria (iOS)
- Each scenario produces the same state changes as Android (golden tests).
- If one step fails, the reply does not claim the full scenario.

## 11. Existing Android tests
`T/tools/ComfortScenariosTest`.

## 12. Source references (Android)
`A/vehicle/ComfortScenarios.kt:29-58`; `A/voice/DriverTurnPipeline.kt:395`.

## 13. Implementation constraints


## iOS notes (PROPOSED unless labelled)
Portable (A).
