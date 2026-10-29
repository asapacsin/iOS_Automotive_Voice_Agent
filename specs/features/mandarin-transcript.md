# F-05a Mandarin input transcript on the phone (普通话识别不再被当成葡萄牙语)

**Status:** DRAFT 2026-10-29, waiting for owner approval (H-F05a). iOS only. Owner report 2026-10-29 (device run
aba6829): "the input sometimes interpret as portugese even though that is actually mandarin". Owner chose the
on-device recognizer 2026-10-29: "Use Apple's on-device recognizer for the transcript … locked to zh-CN and ignore
Gemini's guess."
**Depends on:** F-05 (Gemini Live session, `RealtimeEvent.userTranscript`), F-03 (capture frames), F-04 / F-04a
(uplink gate: which frames are the driver's utterance), F-02 (`ListeningIntent` stop phrase), F-09
(`GuardContext.said`), F-14 §8 (echo filter), contracts/voice-agent.md, contracts/audio.md

## 1. Problem (code at aba6829)
- `GeminiCodec` sends `inputAudioTranscription: {}`. The Gemini Live API takes no language hint for the input
  transcript; `speechConfig.languageCode = zh-CN` only sets her **reply** voice. Gemini detects the language per
  utterance, and short or noisy Mandarin sometimes comes back as Portuguese text.
- That text is not only a subtitle. `AgentState` (`.userTranscript`) feeds it to:
  1. the subtitle (what the driver sees as 「你说的」),
  2. the stop phrase (`ListeningIntent.classify` → 别说了 barge-in, owner rule 2026-10-28),
  3. the echo filter (`relay.isEcho`, F-14 §8),
  4. `pipeline(.driverUtterance)` → `GuardContext.said` for every word-based tool guard (F-09: P56, P57, P61, P66,
     vague exit, …).
- A Portuguese transcript therefore (a) shows the driver nonsense, (b) cannot match 别说了, so she does not stop,
  and (c) silently disables every word-based guard: the guards look for Chinese words, find none, and let the tool
  call through. The model still hears the audio and may act on it, so the safety net is gone exactly when
  recognition is weakest.

## 2. User-facing behaviour
- The driver speaks Mandarin only (owner rule 2026-10-28: she replies only in Mandarin; input is Mandarin). The
  subtitle of the driver's words is **always Chinese text from the phone's own recognizer** (`zh-CN`), never a
  Gemini guess in another language.
- Partial text appears while the driver speaks (≤ 500 ms behind the voice); the final text replaces it when the
  utterance ends.
- Recognition runs **on the phone** (`requiresOnDeviceRecognition = true`): no audio goes to Apple, it works without
  network, and nothing changes on the Gemini side (Gemini still receives the same audio and answers from it).
- First use asks one extra permission: 「语音识别」 (`NSSpeechRecognitionUsageDescription`:
  「小诺在手机上把你说的普通话转成文字，用来显示字幕和识别"别说了"等指令，录音不会上传。」). It is asked together with
  the first microphone use, not at app start.
- If the phone cannot recognise on device (permission denied, `zh-CN` on-device model not available on this
  phone or iOS version, recognizer error), the app falls back to Gemini's transcript **with the language check of
  §8**: text that is not Chinese is never shown as the driver's words and never treated as current words.
- 设置 → 音频测试 shows one diagnostics line: `识别：本机 zh-CN` or `识别：云端（本机不可用：<reason>）`.

## 3. Preconditions
- iOS 17+ with `SFSpeechRecognizer(locale: zh-CN).supportsOnDeviceRecognition == true` (iPhone A12 or newer; the
  test phone is fine). If not supported, §8 fallback.
- New Info.plist key `NSSpeechRecognitionUsageDescription` (App/xtool-Info.plist and codemagic build).
- No new credential, no network service.

## 4. Inputs and outputs
- **New port** (NovaPorts): `LocalTranscriber`
  ```
  protocol LocalTranscriber: Sendable {
      var availability: TranscriberAvailability { get async }      // .ready | .unavailable(reason)
      func begin(utterance: UtteranceID) async                      // a new utterance opens (uplink gate opens)
      func append(_ frame: PCMFrame) async                           // the same frames that go up to Gemini
      func end(utterance: UtteranceID) async                        // the utterance closed (activityEnd)
      var events: AsyncStream<LocalTranscript> { get }              // .partial(id, text) / .final(id, text) / .failed(id, reason)
  }
  ```
- **Adapter** (Packages/NovaAudio): `AppleSpeechTranscriber` on `SFSpeechRecognizer(locale: zh-CN)` with
  `SFSpeechAudioBufferRecognitionRequest`, `requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true`,
  `taskHint = .dictation`, `addsPunctuation = false`. One request per utterance; frames are the 16 kHz mono capture
  frames converted to an `AVAudioPCMBuffer`.
- **Pure policy** (NovaCore, NovaVoice/Transcript): `TranscriptSelector` turns (local events, Gemini
  `userTranscript` events, utterance boundaries, clock) into the **one** `userTranscript(text, isFinal)` stream that
  `AgentState` already consumes, plus a `wordsReliable: Bool` flag carried into `GuardContext`.
- Output to the rest of the app is unchanged in shape: `AgentState` still sees `.userTranscript(text, isFinal:)`;
  only its source changes. No change to the Gemini protocol or `RealtimeEvent`.

## 5. Rules of `TranscriptSelector`
| # | Situation | Result |
|---|---|---|
| S1 | Local transcriber ready | Local partials are forwarded as `isFinal: false`; the local final as `isFinal: true`. Gemini's input transcript for that utterance is **dropped**. `wordsReliable = true`. |
| S2 | Local final not yet in when Gemini's turn needs it | Wait up to `localFinalWait` = 800 ms after the utterance ends; then use the last local partial as final. Only if there is no local text at all, go to S3. |
| S3 | Local unavailable or failed for this utterance | Use Gemini's transcript through the language check (§8). |
| S4 | Language check fails (S3 text is not Chinese) | Subtitle shows 「（没听清）」; the text is **not** passed as the driver's words: stop-phrase check skipped, `wordsReliable = false`. |
| S5 | Local text is empty (silence or noise passed the gate) | No subtitle, no `driverUtterance`; same as today for an empty Gemini transcript. |
- Traditional characters are kept as recognised; matching code already folds them (`traditional` map in
  `ToolCallGuards`).
- The stop phrase (F-02/F-08) is checked on **local partials** too, so 别说了 stops her as soon as the phone hears it,
  without waiting for Gemini (keeps the owner rule 2026-10-28 and makes it faster).

## 6. Guards when the words are not reliable
- `GuardContext` gains `wordsReliable`. When it is false, guards that **allow** an action only on the driver's words
  (e.g. `set_speech_output` P66, the F-15a start guard) refuse with `.wordsUnclear`; she says one honest sentence:
  「没听清，请再说一遍。」 Guards that only **narrow or block** keep working as today.
- This closes the hole of §1(c): a transcript that could not be read never counts as permission.

## 7. Dependencies and external services
- `Speech` framework only in Packages/NovaAudio (`scripts/gates/check_imports.py`: add `"Speech": {"NovaAudio"}`).
  `TranscriptSelector`, `LocalTranscriber` and their tests are pure Swift in NovaCore (Linux gates).
- No network. Gemini setup unchanged (`inputAudioTranscription` stays on; it is the S3 fallback).

## 8. Error handling and recovery
- **Language check** (pure, `TranscriptLanguage.isChinese(text)`): true when ≥ 60 % of the letters are Han
  characters (CJK Unified Ideographs, incl. Ext. A) and the text has at least one Han character; digits and
  punctuation are ignored. Latin-only text (Portuguese, English) is false.

| Case | Behaviour |
|---|---|
| Speech permission not asked | asked with the first microphone use |
| Permission denied / restricted | S3 fallback; diagnostics `云端（本机不可用：未授权）`; no repeated prompt |
| On-device `zh-CN` not supported | S3 fallback; diagnostics reason `本机不支持` |
| Recognizer task error mid-utterance | this utterance S2/S3; next utterance tries local again |
| Audio session interruption (call, Siri) | the request is cancelled with the utterance; no stale final is forwarded (utterance id check) |
| Recognizer's 1-minute request limit | one request per utterance; utterances are far shorter (F-04 max) |
- I-8: no transcript text in logs, local or fallback. Diagnostics carry only the source (`local`/`gemini`), the
  language-check result and latencies.

## 9. Concurrency, cancellation, timeouts
- The adapter runs off the main actor; frames are appended in capture order. Every event carries its
  `UtteranceID`; the selector drops events of a closed or superseded utterance.
- Barge-in / interruption ends the utterance: the request is finished, not cancelled, so the final arrives (S2 wait).
- CPU: on-device recognition runs only while the uplink gate is open (the driver is speaking), not continuously.

## 10. Acceptance criteria (iOS)
| # | Criterion | Level |
|---|---|---|
| 1 | `TranscriptSelector` S1–S5: local wins, Gemini dropped; 800 ms final wait; fallback; language check blocks non-Chinese; empty text ignored | unit |
| 2 | `TranscriptLanguage.isChinese`: Mandarin sentences true; Portuguese/English false; mixed 「导航去 Costa」 true; digits-only ignored | unit |
| 3 | Stop phrase from a local partial stops her (no Gemini transcript involved) | unit (AgentState with selector) |
| 4 | `wordsReliable = false` → allow-type guards refuse with `.wordsUnclear`; block-type guards unchanged | unit |
| 5 | 30 short Mandarin commands on the phone (incl. 2-character ones: 别说了, 算了, 回家, 好的): subtitle always Chinese, never Portuguese/Latin; ≥ 27/30 correct characters | D |
| 6 | Airplane mode: subtitles still appear (on-device) while the session is down | D |
| 7 | Speech permission denied: app still works, subtitles from Gemini only when Chinese, 「（没听清）」 otherwise; diagnostics line shows the reason | D |
| 8 | No transcript text in the phone log during rows 5–7 (log capture) | D |
| 9 | Partial subtitle latency ≤ 500 ms behind speech; final ≤ 800 ms after the utterance ends | D |

## 11. Implementation constraints
- Test names carry `F-05a` for the spec-trace gate.
- `LocalTranscriber` in NovaPorts; `TranscriptSelector` and `TranscriptLanguage` in NovaCore/NovaVoice; adapter
  in NovaAudio; composition in the App target (`AgentRuntime` feeds the uplinked frames to both Gemini and the
  transcriber).
- App target changes need an iOS build (Codemagic, started only when the owner asks; owner rule 2026-10-27, no
  macOS GitHub runners). Device rows stay NOT_VERIFIED until a phone run.

## Open questions
- OQ-STT-1 (default: **no**) Show the local text even while Gemini's answer is already playing for the previous turn?
  Default: the subtitle area shows the newest utterance only, as today.
- OQ-STT-2 (default: **Mandarin only**) Cantonese input? Out of scope; owner rule says Mandarin. A Cantonese
  utterance is recognised as Mandarin text (possibly wrong) and Gemini still hears the audio.

## Tasks (implementation-plan.md M1 follow-up, specs/work.json)
| ID | Task | Verification |
|---|---|---|
| T-016a | `LocalTranscriber` port, `TranscriptSelector`, `TranscriptLanguage`, `GuardContext.wordsReliable` + `.wordsUnclear`; rows 1–4 | unit (Linux gates) |
| T-016b | `AppleSpeechTranscriber` (NovaAudio), import gate entry, Info.plist key, permission with first mic use | build |
| T-016c | Wire into `AgentRuntime` (frames to transcriber, selector in front of `AgentState`), 音频测试 diagnostics line; rows 5–9 | S, D |
