# Open EVIDENCE_REQUESTs (batch 2, 2026-10-26)

Raised per specs/ai-agent-workflow.md. A human or a read-only helper answers each with the excerpt and
the Android commit; the answer is appended to the named feature file (version bump) and the PROPOSED
iOS value is replaced. Agents do not open the Android repo for these.

```
EVIDENCE_REQUEST
feature: F-25
question: bubble fade constants (show/hold/fade durations, per-character extension) — blocks T-025
android_ref: A/ui/TranscriptBubbleFade.kt
```
```
EVIDENCE_REQUEST
feature: F-06
question: claim and request phrase tables replacing PROPOSED ClaimLexicon
android_ref: A/voice/ActionClaimGuard.kt:447,671
```
```
EVIDENCE_REQUEST
feature: F-06
question: DriverTurn intent tables for navigation/music requests (「去机场」「来点周杰伦的」)
android_ref: A/voice/DriverTurnPipeline.kt:395
```
```
EVIDENCE_REQUEST
feature: F-16
question: verb/filler/category stripping tables and expected queries
android_ref: T/nav/DestinationQueryTest
```
```
EVIDENCE_REQUEST
feature: F-14
question: GuidanceRelay prompt wording, reason codes and their order, cooldown
android_ref: A/voice/GuidanceRelay.kt
```
```
EVIDENCE_REQUEST
feature: F-04
question: 600 ms evidence window and noise-bed adaptation rate; noise-bed PCM corpus
android_ref: A/voice/SpeechUplinkGate.kt:299-377, T/voice/SpeechUplinkGateNoiseBedTest
```
```
EVIDENCE_REQUEST
feature: F-02
question: full ListeningIntent phrase table and whether 闭嘴 stays local while a picker is open
android_ref: A/voice/ListeningIntent.kt:21
```
```
EVIDENCE_REQUEST
feature: F-17
question: HUD turn table, distance rounding, speed-limit precedence
android_ref: A/nav/HudPanel*.kt
```
```
EVIDENCE_REQUEST
feature: F-19
question: call confirmation window length (iOS PROPOSED 30 s)
android_ref: A/phone/*Confirm*.kt
```
```
EVIDENCE_REQUEST
feature: F-12
question: mosquito flag expiry
android_ref: A/vehicle/ComfortScenarios.kt:29-58
```
