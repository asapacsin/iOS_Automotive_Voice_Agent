# F-04b Speaker Lock: only the enrolled voice can use her (声纹锁定)

**Status:** APPROVED (owner request 2026-11-05). iOS only. Default OFF.
**Depends on:** F-03 (capture), F-04 and F-04a (uplink gate, speech confirmation), F-01 §14 (wake word, T-060a), F-08 (stop phrases, interruption), F-22 (settings), contracts/audio.md, contracts/voice-agent.md

## 1. Purpose

With the lock on, only the enrolled speaker's voice reaches Gemini, wakes her or interrupts her. With the lock off, anyone can use her, as today.

**Limit, stated in the app and docs.** This is basic speaker verification. It does not separate overlapping voices and it can be wrong in both directions. It is a convenience, not a security feature, and a recording of the driver's voice can pass it.

## 2. Sources and model choice (2026-11-05)

- The bundled sherpa-onnx library already has `SherpaOnnxCreateSpeakerEmbeddingExtractor` in its C API at the pinned release, so no new library is needed.
- **Model: `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced`** (CAM++, zh and en, about 28 MB, from the [sherpa-onnx speaker models](https://huggingface.co/csukuangfj/speaker-embedding-models/tree/main)). The Apache-2.0 licence comes from a [secondary source](https://huggingface.co/openEuler/campplus-speaker). T-013e checks the primary 3D-Speaker model card before pinning; if the licence does not allow this use, stop and report it. **Checked 2026-11-05 (T-013e):** the primary ModelScope card `iic/speech_campplus_sv_zh_en_16k-common_advanced` (3D-Speaker team) states `license: Apache License 2.0`; pinned at `csukuangfj/speaker-embedding-models` revision `0743f301`, sha256 `aa3cfc16…ceba2`.
- Rejected: [Picovoice Eagle](https://picovoice.ai/docs/api/eagle-nodejs/) (needs a vendor key and account); WeSpeaker VoxCeleb models (listed as cc-by-4.0 by a third party, and English-trained).
- Pattern: [Picovoice's secure wake word recipe](https://picovoice.ai/cookbook/personalized-wake-word/) checks the voice on the audio around the wake word, and triggers only on a match. Enrollment [works best](https://picovoice.ai/docs/api/eagle-nodejs/) with one speaker in a normal voice, with no background sound.
- No source gives a threshold or short-utterance accuracy for this model in a car, or iPhone latency. These are measured here (§8).

## 3. Settings (`Section("声音")`)

1. **声纹锁定** switch, default off, read without restarting. Text: 「开：只有录入的声音能唤醒和使用小诺。说话重叠时可能听不准。」
2. Status 「未录入」, 「已录入，未校准」 or 「已录入」.
3. Buttons: **录入声纹** (not enrolled), **重新录入** and **校准** (enrolled), **删除声纹** with a confirmation.
4. **The lock cannot be on when it would not work.** Turning it on with no calibrated profile opens the next step (录入 or 校准) and the switch stays off until that succeeds. If the model cannot load, the switch stays off and shows 「声纹模型不可用」.
5. 危险操作's wipe-all also deletes the profile.

## 4. Enrollment

1. **Guided:** the driver reads 3 short Chinese sentences on screen, in a quiet parked car, for about 15 s in total. It runs only with no session running, and the wake listener lets go of the microphone (one capture only, ADR-006).
2. **Same audio path:** it uses the same voice-processing capture as a live session, so enrollment audio matches live audio.
3. **Checks before saving:** at least 8 s of confirmed speech (F-04a), no clipping, and a noise level below a constant. The embeddings of the 3 sentences must agree with each other, which catches a second voice or a bad take. A failed check names the problem and asks for a retry. Nothing is saved.
4. **Stored:** the averaged embedding, model name, dimension, threshold and date, in one file under Application Support, with `completeUntilFirstUserAuthentication` protection, excluded from backup. Raw audio stays in memory only and is dropped when enrollment ends.
5. **Replace and delete:** re-enrolling replaces the file only after the new one passes. Deleting removes the file and turns the lock off.
6. **Model change:** a profile whose model name or dimension differs is invalid; the lock turns off and the status says to re-enroll.
7. **Nothing leaves the phone.** No embedding, score or audio goes to any cloud service for this feature.

## 5. Threshold: calibrated, never assumed

1. There is no built-in threshold. It is `nil` until 校准 sets it, and the lock cannot turn on while it is `nil`.
2. **校准** asks for 20 short everyday lines from the enrolled driver and 20 from another person, with the option of more people. Those lines are not the enrollment sentences. Scores are kept, audio is not.
3. It shows the false reject and false accept counts at each candidate threshold, and suggests the lowest threshold with no false accepts. The owner confirms it, and it is saved in the profile. It also says plainly that 0 of 20 false accepts is weak evidence: the true rate could still be about 14%.
4. Scores go to a local file in the Documents folder and can be pulled over USB, so the result can be checked.
5. `scripts/speaker_eval.py` computes false accept and false reject rates and score spread on a folder of labelled clips, using the same model through the sherpa-onnx Python package, so it runs on a PC or in the cloud. It does not need the phone, and no audio is added to the repo unless its licence allows it.

## 6. Live pipeline

Microphone → voice processing → speech confirmation → `SpeechUplinkGate` → local words → **`SpeakerHold`** → `PostStopHold` → Gemini.

1. **Ports.** `SpeakerVerifier` port in `NovaPorts`: frames in, embedding score out. The adapter is in `NovaAsrSherpa`, and no Gemini code knows about it. Inserting a target-speaker extractor later means adding a stage before this port; no extractor is built now.
2. **Pure `SpeakerHold` in `NovaVoice`.** With the lock on, it takes `speechStarted`, its pre-roll, the audio and the end marks, and holds them in order. Nothing goes to Gemini until the utterance is accepted.
3. **Off the audio thread.** Scoring runs on one background serial queue. The capture callback only copies frames. It runs once when the utterance reaches `minVerifySpeech`, or at its end if sooner; it does not rescore continuously. `minVerifySpeech` starts at 1.0 s and changes only from the measurements.
4. **Results.**
   - **Accepted:** all held output is released in original order, with the pre-roll, so no first word is lost; the rest of the utterance passes straight through.
   - **Rejected:** everything for that utterance is dropped. It counts as not sent: no activity marks, no driver turn, no tool call, no reply clock, and no driver line on screen.
   - **Unknown** (under `minScoreSpeech`, starting at 0.5 s, a scoring failure, or a held buffer past 3 s): treated as rejected. Unknown never counts as accepted, and no made-up confidence is reported.
5. **Stale results.** Each check carries the utterance id and session generation. A result for anything else is dropped, and pending state resets on every utterance end, session stop and lock change.
6. **Overlap.** No overlap detector is added. A mixed voice gets whatever score it gets, and normally goes through the same reject path. It is measured and reported, not claimed as handled.
7. **Wake word.** The wake listener keeps the last 2 s of frames. On a detection with the lock on, the phrase's audio is scored before `start()`. Not accepted means she stays asleep, the listener stays armed, and `wake-rejected` is recorded. Needs T-060a.
8. **Stop phrases.** With the lock on, a spotted stop phrase is scored on its own recent audio before it stops her. Not accepted means she continues. 「停」 is too short to verify reliably, so row 12 measures it, and the owner decides from that whether it stays.
9. **Interruption.** With the lock on, `BargeInLive` acts only on an accepted utterance: no dip or stop before acceptance.
10. **Switching during a session.** Turning it off releases any held utterance and stops scoring. Turning it on applies from the next utterance. Neither restarts the session.
11. **If scoring breaks while locked.** It fails closed: speech is not sent, and the chip says 「声纹不可用，可在设置关闭」. The talk button and the settings still work.
12. **Lock off.** `SpeakerHold` is bypassed completely, no model is loaded and no scoring runs. Outputs are byte-for-byte what they are today.

## 7. Seeing what happened

Record lines, numbers only: `speaker-check utterance=<id> kind=<speech|wake|stop> score=<n> threshold=<n> result=<accepted|rejected|unknown> speechMs=<n> scoreMs=<n> waitMs=<n>`. The utterance line's `muteReason` gains `speaker`. `RuntimeLog` gets the same numbers with no words or audio (I-8).

## 8. Acceptance (iOS)

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Lock off, a scripted utterance | Outputs equal today's; no verifier call and no model load | unit |
| 2 | Lock on: accepted at 1.0 s | Nothing is forwarded before the result; then the pre-roll and frames in original order, with no gap or duplicate | unit |
| 3 | Lock on: rejected; unknown; scoring failure; buffer past 3 s | Nothing is forwarded; no driver turn, tool call or driver line; `muteReason=speaker` | unit |
| 4 | A late result for an old utterance or old session | Dropped; it cannot authorize the new one | unit |
| 5 | Lock on to off with an utterance held; off to on mid-utterance | Released in order; the open utterance continues, and the next one is verified | unit |
| 6 | Enrollment: too short, clipped, sentences that disagree | Not saved, with the reason shown | unit |
| 7 | Profile: save and reload; re-enroll fails; delete; model name changes; wipe-all | Survives reload; the old one is kept; removed and lock off; invalid and lock off; removed | unit |
| 8 | Switch on with no profile, or no threshold | Enrollment or calibration opens; the switch stays off until it succeeds | unit |
| 9 | Wake and stop phrase with the verifier rejecting, then accepting | No start and no stop, then start and stop | unit |
| 10 | `scripts/speaker_eval.py` on real, labelled clips | Reports false accept and reject rates; the labels and source are written down; not mocked scores | script |
| 11 | Device: enroll, close and reopen the app | Status and lock preference survive; no second enrollment | D |
| 12 | Device, lock on, parked: driver 30 lines, including short ones (「第一个」, 「打开空调」, 「停」) | Note false rejects by length, and whether first words are kept | D |
| 13 | Device, lock on: passenger 30 lines, with commands, 「你好小诺」 and 「别说了」 | Note false accepts; no tool action from any rejected line | D |
| 14 | Device, lock off: driver and passenger | Both work as before | D |
| 15 | Device: turn the lock on and off during a session | Takes effect with no restart | D |
| 16 | Device: driver and passenger talk at once, 10 times | Note what happens; no claim of separation | D |
| 17 | Device, lock on and off: 20 turns each | Note added delay (`waitMs`, `scoreMs`), CPU, memory, and the 响应速度 sheet | D |
| 18 | Device: repeat rows 12–13 while driving with road noise | Note the rates; calibration in a parked car may not hold here | D |

## 9. Not changed

Echo cancellation, noise suppression, VAD rules, the wake word engine, the Gemini setup, and everything with the lock off. No new subagents, no new cloud service.

## 10. Implementation notes

- **Delay.** Holding until 1 s of speech adds about that much before audio starts going up, on top of the times in the 响应速度 sheet. Row 17 measures it.
- **App size.** The app grows by about 28 MB. `scripts/fetch_sherpa_models.sh` and `scripts/sherpa/models.sha256` pin the model, as for ASR and KWS.
- **Docs.** Update `specs/ios-architecture.md` (§3.2 and the ports table), `specs/features/README.md` and `specs/STATUS.md`.
- **Trace gate.** Add `T-013e: F-04b` to `specs/trace-ids.txt` together with the first `@Test` that names F-04b; the gate fails before a test exists.
- **Decision.** No pass bars are set here. The owner reads rows 12–18 and decides whether the lock stays, what threshold to use, and whether 「停」 needs its own rule.

## 11. Tasks

| Task | Scope | Verify |
|---|---|---|
| T-013e | §3–§10; rows 1–18 | unit, script, build, D |
