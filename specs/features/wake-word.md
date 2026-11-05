# F-01 Wake word

**Android status:** IMPLEMENTED (iFlytek MSC, offline). Device-fired 2026-09-19 (SPEC-001); WAKE-ENGINE/WAKE-SYNTH rows NOT_RUN.
**Depends on:** contracts/audio.md, contracts/voice-agent.md §2, F-02

## 1. Purpose
Start or resume a conversation hands-free with the wake phrase (你好小诺; baked into the `.jet` model, not a string in code — UNVERIFIED wording).

## 2. User-facing behaviour
- Idle (SLEEP or DEEP_IDLE): saying the wake phrase starts listening; the chip shows 聆听中.
- A tap on the assistant button does the same.
- A late or duplicate wake callback never starts a second session.

## 3. Preconditions
Microphone permission; iFlytek app id configured; session not already ACTIVE.

## 4. Inputs and outputs
In: 16 kHz PCM frames from the shared capture. Out: one `wake` event.

## 5. State transitions
Detector: IDLE → AUTHORISING → READY → LISTENING; ERROR on failure. Wake counts only while armed (`WakeArming`).

## 6. Events and triggers
Wake fires → listening lifecycle SLEEP→ACTIVE (same connection) or DEEP_IDLE→ACTIVE (new session).

## 7. Dependencies and external services
iFlytek MSC SDK, offline model `ivw/wakeword.jet`, threshold `0:1450`.

## 8. Error handling and recovery
Capture/engine failures retry with bounded backoff: base 1.5 s, max 30 s, 6 attempts (`BoundedRetry`).

## 9. Concurrency, cancellation, timeouts
Controller reconciles every 1.5 s on the main thread. While idle the wake detector owns the mic; when a session starts it hands the stream over (one capture only, ADR-006).

## 10. Acceptance criteria (iOS)
- Given SLEEP, when the wake phrase is played, then state becomes ACTIVE within the detector latency and exactly one session start occurs.
- Given ACTIVE, when a duplicate wake arrives, then nothing restarts.
- Given engine init fails 6 times, then the app shows wake unavailable and the UI button still works.

## 11. Existing Android tests
`T/wake/WakeArmingTest`, `WakeWordControllerTest`, `WakeWordDetectorTest`, `WakeWordSettingsTest`, `WakeWordCredentialsTest`.

## 12. Source references (Android)
`A/wake/IflytekWakeWordDetector.kt:20,279-286`; `A/wake/WakeWordController.kt:262`; `A/wake/WakeArming.kt:13-19`.

## 13. Implementation constraints
Never two concurrent captures. Wake must work only in the foreground on iOS unless background audio is justified (see ios-feasibility).

## iOS notes (PROPOSED unless labelled)
iFlytek has an iOS wake SDK (`IFlyVoiceWakeuper`, `.jet` resource, threshold `0:1450`), bound to the app id and in-app only (VERIFIED, OQ-IOS-1); the same `.jet` needs the iOS SDK for the same app id (OWNER). Fallback: Picovoice Porcupine custom keyword (PROPOSED). `SFSpeechRecognizer` is not meant for always-on keyword spotting (PROPOSED). Background always-listening on iPhone is restricted; plan for a foreground-only wake word plus a push-to-talk button, CarPlay voice button as optional.

## 14. 你好小诺 works with no account or key (iOS, APPROVED 2026-11-05)

**Why.** Owner 2026-11-05: the wake word is not set up. At 21f4478 the wake code is in the app, but `WakeListener` runs only with three iFlytek values saved in 设置 (`讯飞 APPID`, `APIKey`, `APISecret`), and 你好小诺 has never been verified on a phone (T-064). iFlytek also needs network activation on first use, and a third-party page reports a free trial of 10 devices for 90 days. The owner prefers not to pay. The app already bundles a sherpa-onnx keyword spotter, about 13 MB, used offline for 「别说了」 (F-08 §14). It needs no key, and wake words can be set as text with no retraining.

Sources 2026-11-05: [sherpa-onnx keyword spotting](https://k2-fsa.github.io/sherpa/onnx/kws/index.html) (keywords as tokens, per-keyword threshold and boost); [iFlytek AIKit iOS SDK](https://xfyun.cn/doc/asr/AIkit_awaken/iOS-SDK.html) (licence and first-use activation); [Picovoice](https://picovoice.ai/blog/benchmarking-a-wake-word-detection-engine/), a vendor, on measuring false wakes per hour. No source gives real false-wake numbers for this model on a phone, so rows 9–12 are the real test.

This section replaces the engine in §7, §8 stays. It does not change the foreground-only limit in §13.

1. **The engine.** `SherpaWakeEngine` in `NovaAsrSherpa` implements the existing `WakeEngine` port, with its own `KeywordSpotter` on the bundled `SherpaModels/kws` model. `WakeListener` and `RetryingWakeDetector` stay.
2. **The phrase.** A fixed `WakePhrase` in `NovaVoice`, with two token lines because 你好 is usually said ní hǎo: `n ǐ h ǎo x iǎo n uò` and `n í h ǎo x iǎo n uò`. Both report one wake. `check_kws_tokens.py` also checks these tokens.
3. **Tuning.** Wake threshold and boost are their own constants in `Tuning`, separate from the stop phrases. They start at the current stop-phrase defaults and change only from the device rows.
4. **No keys.** `WakeListenPolicy` no longer needs iFlytek values. The engine counts as available when the KWS model loads. If it does not load, §8 applies: bounded retries, then unavailable, and the talk button still works.
5. **iFlytek is unused, not deleted.** One constant selects the engine, set to sherpa. `AIKitWakeEngine` and the vendored SDK stay until the owner decides from rows 9–12. With sherpa selected, the three 讯飞 fields do not show in 设置.
6. **A setting.** 设置 gets 「唤醒词」, on by default, read when the listener is applied. Off means the listener does not take the microphone. Text: 「开：应用在前台时用手机麦克风等「你好小诺」，声音只在手机上处理。」
7. **The screen stays on while listening.** While the listener runs in the foreground, `isIdleTimerDisabled` is true; it goes back when the listener stops. Without this the phone locks and listening ends. Row 12 measures the battery cost.
8. **What the driver sees.** While armed, the idle screen shows 「说“你好小诺”唤醒」. When unavailable or off, it does not show.
9. **After the wake.** The listener releases the microphone and the session starts, as today. When the session first reaches listening, a short local sound plays once. The driver speaks after the sound. Speech between the wake and the sound is not kept; records show 1.6–2.8 s to connect. Keeping it, so 「你好小诺，打开空调」 works in one breath, is a later decision after row 9.
10. **The sound is not the driver.** It plays through the session's own audio output, so echo cancellation can see it, and it does not open an utterance or stop a reply.
11. **A wake with no words.** If nothing is said, the existing lifecycle ends the session. She says nothing, and the listener takes the microphone again.
12. **Seeing what happened.** The conversation record header adds `startedBy wake|tap`. New record lines: `wake-to-listening ms=<n>`, and `wake-unused` when a woken session ends with no utterance sent, which counts false wakes. `RuntimeLog` gets `wakeDetected`, with no words or audio (I-8). No audio is saved.
13. **What this does not do.**
    - No listening when the app is in the background or the phone is locked. iOS restricts this; see §13.
    - No wake word during a running session, where the existing duplicate rule applies.
    - No custom phrase, and no recognising who is speaking.
14. **Decision.** No pass bars. The owner reads rows 9–12 and decides whether to keep sherpa, change the threshold, or try iFlytek.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | The wake token lines and the KWS token list | Every token is in the list; a token not in it fails `check_kws_tokens.py` | gate |
| 2 | No iFlytek values, model loads, microphone granted, foreground, no session, setting on | `shouldListen` is true | unit |
| 3 | Each one changed: model fails, microphone denied, background, session running, setting off | `shouldListen` is false; the talk button still works | unit |
| 4 | Scripted engine: both phrase forms; a duplicate; a wake after disarm | One wake for each form; the duplicate and the late wake start nothing | unit |
| 5 | Listener starts and stops | The idle timer is disabled, then restored | unit or D |
| 6 | Session started by wake, and by tap | `startedBy` is right; the sound plays once on the first listening, only when started by wake, and not after a reconnect | unit |
| 7 | The sound plays | No utterance opens and no reply stops | unit |
| 8 | Woken session ends with no utterance | `wake-unused` once; the listener is applied again | unit |
| 9 | Device, in the car or a quiet room: 「你好小诺」 20 times, at normal voice, from the driver's seat | Note the hits, and `wake-to-listening` | D |
| 10 | Device: 20 times with the air conditioning on high or road noise | Note the hits | D |
| 11 | Device, 1 hour with normal talk, radio or video, and once navigation guidance with no session | Note `wake-unused` per hour; guidance must not wake it | D |
| 12 | Device: 1 hour idle with the listener on, screen on | Note battery used and whether the phone gets hot | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-060a | Items 1–14; rows 1–12 | gate, unit, build, D |
