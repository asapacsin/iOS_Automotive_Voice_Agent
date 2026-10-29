# F-04a Noise suppression: only a human voice opens the microphone or interrupts her

**Status:** APPROVED (owner request 2026-10-27: "noise suppression function to avoid sound other than human voice
interrupt in the input"). iOS only. Extends [F-03 Microphone capture, AEC and gain](audio-capture-aec.md),
[F-04 Uplink gate](uplink-gate.md) and [F-08 Barge-in](barge-in-arbitration.md). Defaults below are decided;
OQ-NS-1/2 stay open with the recommended answer used until the owner says otherwise.
**Depends on:** F-03, F-04 (T-013 `SpeechUplinkGate`), F-08, contracts/voice-agent.md §3

## 1. Purpose
In a car the microphone hears road and wind noise, the horn, indicators, doors, music, and her own voice from
the speaker. Today the local gate (F-04) opens on **energy and voicing** alone, so a loud non-speech sound can
open the uplink (the model then hears noise and answers 「没听清」) or cut her off mid-sentence (F-08).
This feature makes **human speech the only thing** that opens the uplink or interrupts her.

## 2. User-facing behaviour
- Horn, indicator ticks, door slams, a dog, road/wind noise, music without vocals: she does not react, does not
  stop talking, and the status chip stays 聆听中 / 说话中.
- The driver speaks over the same noise: she reacts as before (status → 聆听中 → 思考中), no extra delay
  noticeable in normal speech (budget in §9).
- While she talks, only the driver's voice interrupts her; her own voice from the speaker never does (AEC + §4).
- 设置 → 声音 → **抗噪** switch (default **开**). Off = today's F-04 behaviour (for diagnosis).
- 音频测试 tab shows a live line: `语音概率 0.91 · 噪声 62 dB · 上次拒绝：喇叭` so a tester can see why a sound
  was ignored (labels only, no audio stored).

## 3. Preconditions
Capture running (F-03); lifecycle ACTIVE or SILENT_WAIT (F-04). No extra permission: everything runs on the
device; no audio leaves the phone except gated speech (unchanged privacy rule, I-8).

## 4. Inputs and outputs
Three layers, in this order on the capture path:
1. **Apple voice processing** (F-03, already on): `AVAudioInputNode.setVoiceProcessingEnabled(true)`, which gives
   echo cancellation, noise suppression and AGC. This feature pins it: `isVoiceProcessingBypassed = false`,
   `isVoiceProcessingAGCEnabled = true`, and other-audio ducking `.min` so her playback is not ducked into the
   mic path. A run that finds voice processing unavailable logs `VOICE_PROCESSING_OFF` and keeps going (layers
   2–3 still apply).
2. **Speech classifier** (new): Apple SoundAnalysis `SNClassifySoundRequest(classifierIdentifier: .version1)` over
   the cleaned 16 kHz mono frames, window 0.5 s, overlap 0.75 (a result every 125 ms). Output per window:
   `speechProbability` = max of the `speech`, `conversation`, `shout`, `whispering` labels;
   `topNonSpeech` = the best non-speech label (e.g. `car_horn`, `music`, `wind`) for diagnostics.
3. **Gate rule** (pure, NovaVoice/Uplink `SpeechConfirmation`): the F-04 gate's `closed → onset` step still uses
   energy/voicing, but **onset → open** now also needs `speechProbability ≥ 0.6` in at least 2 of the last 3
   windows (`TuningDefaults.speechConfirm`). Until confirmed, frames stay in the pre-roll buffer and nothing is
   uploaded; a confirmed onset uploads the buffered pre-roll (300 ms, F-04) so the first syllable is kept.
   An onset not confirmed within 600 ms is dropped as `REJECTED_NON_SPEECH` with `topNonSpeech` as the reason.
- **Barge-in (F-08)**: while she speaks, an interruption needs the same confirmation **and** the AEC residual
  rule of F-08; a non-speech onset never sends `interrupt`.
- Output events are unchanged (SpeechStarted/Stopped, audioStreamEnd); a new diagnostic event
  `UplinkRejected(reason)` goes to logs and the 音频测试 line only.

## 5. State transitions
F-04: `closed → onset → (confirming) → open → hangover → closed`. New sub-state `confirming` (≤ 600 ms) between
onset and open; `confirming → closed` on rejection. Hangover (1200 ms) keeps using energy/voicing only, so a
short noise during a pause in speech does not cut the driver off.

## 6. Events and triggers
Capture frames; classifier results; the 抗噪 switch (read at session start and on change); lifecycle changes
(F-02) reset the classifier state.

## 7. Dependencies and external services
- AVFoundation voice processing (NovaAudio, F-03).
- SoundAnalysis (`SNAudioStreamAnalyzer`) in **NovaAudio** only (I-9: Apple frameworks stay in adapters);
  NovaCore receives plain `SpeechClassification(speechProbability, topNonSpeech, at)` values through a port
  `SpeechClassifier` in NovaPorts.
- No network service. No third-party model.

## 8. Error handling and recovery
| Case | Result |
|---|---|
| Classifier fails to start / throws | log `SPEECH_CLASSIFIER_FAILED`; gate falls back to F-04 rules (energy/voicing); 音频测试 line says 抗噪不可用 |
| Classifier late (no result within 300 ms of onset) | treat as not confirmed yet; give up at 600 ms → fall back to F-04 for that onset (never lose real speech for a slow classifier) |
| Voice processing unavailable | `VOICE_PROCESSING_OFF` logged; layers 2–3 still run |
Codes only in logs; audio and labels are never uploaded (I-8).

## 9. Concurrency, cancellation, timeouts
Classifier on its own serial queue fed from the capture tap; it never blocks capture. Added onset latency budget:
**≤ 250 ms** median, ≤ 400 ms p95 for speech at 10 dB SNR (measured from onset to first uploaded frame). CPU
budget: classifier ≤ 10 % of one core on iPhone 15 or newer (Instruments, D).

## 10. Acceptance criteria (iOS)
| # | Criterion | Level |
|---|---|---|
| 1 | Corpus clips (horn, indicator, door slam, dog, wind, road noise 70 dB, instrumental music, keyboard): no SpeechStarted, no upload, no interrupt (recorded PCM through the gate with a scripted classifier) | unit |
| 2 | Speech over road noise (SNR 10 dB and 5 dB): SpeechStarted, pre-roll kept, onset latency within §9 | unit (scripted), D |
| 3 | While she speaks: horn / music do not interrupt; the driver's 「停一下」 does (F-08 timing kept) | unit, D |
| 4 | Her own voice from the phone speaker at full volume never opens the uplink (10 replies) | D (ECHO-001) |
| 5 | Classifier failure or late result falls back to F-04, no speech lost | unit |
| 6 | 抗噪 off → F-04 behaviour exactly (existing gate tests unchanged) | unit |
| 7 | 音频测试 line shows speech probability and the last rejection reason | S, D |
| 8 | Classifier CPU and onset latency within §9 on the test iPhone | D |

## 11. Implementation constraints
- The confirmation rule is pure Swift in NovaVoice/Uplink with a scripted `SpeechClassifier` fake; thresholds in
  `TuningDefaults`, re-tuned with `tools/speech-harness` (F-04 §13).
- SoundAnalysis code only in NovaAudio; `scripts/gates/check_imports.py` must keep NovaCore free of it.
- The test corpus lives under `Fixtures/audio/noise/` as 16 kHz mono PCM with a README naming each clip's source
  and licence; no recordings of people other than consenting testers.
- The demo (demo-recording.md) uses 抗噪 on.

## Open questions
- OQ-NS-1 (default: **not handled**): voices from the car radio or a podcast are human speech and pass the
  classifier. Should media playing from this app be paused while listening, or speaker diarization be added later?
  Recommendation: leave it for now; AEC already removes audio the app itself plays.
- OQ-NS-2 (default: **0.6**): speech-probability threshold; raise to 0.7 if device runs show false opens.

## Tasks (implementation-plan.md M1, specs/work.json)
| ID | Task | Verification |
|---|---|---|
| T-013a | `SpeechClassifier` port + `SpeechConfirmation` gate rule (confirming state, fallback, 抗噪 switch) | unit |
| T-013b | NovaAudio `SoundAnalysisSpeechClassifier` (SNAudioStreamAnalyzer, 0.5 s window, own queue); voice processing pinned | build, D |
| T-013c | Barge-in uses the confirmation; 音频测试 diagnostics line; 设置 抗噪 switch | unit, S, D |
| T-013d | Noise corpus fixtures + corpus tests (rows 1–3, 5–6) | unit |
