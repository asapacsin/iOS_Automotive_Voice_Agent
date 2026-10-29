# F-05a Mandarin input transcript on the phone (普通话识别不再被当成葡萄牙语)

**Status:** APPROVED 2026-10-29 (owner: "Approve defaults"; OQ-STT-1 no, OQ-STT-2 Mandarin only). iOS only. Owner report 2026-10-29 (device run
aba6829): "the input sometimes interpret as portugese even though that is actually mandarin". Owner chose the
on-device recognizer 2026-10-29: "Use Apple's on-device recognizer for the transcript … locked to zh-CN and ignore
Gemini's guess."
**Revised 2026-10-29:** the transcript is for display only; no tool guard reads it (§6, owner rule after run 9f48c45).
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
     vague exit, …). Revised 2026-10-29: this use is removed (§6); the transcript is for display only.
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
  `AgentState` uses for the subtitle, the stop phrase and the echo filter (no guard input, §6).
- Output to the rest of the app is unchanged in shape: `AgentState` still sees `.userTranscript(text, isFinal:)`;
  only its source changes. No change to the Gemini protocol or `RealtimeEvent`.

## 5. Rules of `TranscriptSelector`
| # | Situation | Result |
|---|---|---|
| S1 | Local transcriber ready | Local partials are forwarded as `isFinal: false`; the local final as `isFinal: true`. Gemini's input transcript for that utterance is **dropped**. |
| S2 | Local final not yet in when Gemini's turn needs it | Wait up to `localFinalWait` = 800 ms after the utterance ends; then use the last local partial as final. Only if there is no local text at all, go to S3. |
| S3 | Local unavailable or failed for this utterance | Use Gemini's transcript through the language check (§8). |
| S4 | Language check fails (S3 text is not Chinese) | Subtitle shows 「（没听清）」; stop-phrase check skipped. Tool calls are unaffected (§6). |
| S5 | Local text is empty (silence or noise passed the gate) | No subtitle, no `driverUtterance`; same as today for an empty Gemini transcript. |
- Traditional characters are kept as recognised; matching code already folds them (`traditional` map in
  `ToolCallGuards`).
- The stop phrase (F-02/F-08) is checked on **local partials** too, so 别说了 stops her as soon as the phone hears it,
  without waiting for Gemini (keeps the owner rule 2026-10-28 and makes it faster).

## 6. The transcript is for display only (revised 2026-10-29)
Owner rule 2026-10-29, after device run 9f48c45 (「最快的」 refused three times because the transcript was unreadable or
off the word list): "abandon the transcript that serve the tool calling, and the transcript only use for display the
text on the screen". This matches common practice: Gemini Live's input transcript is a separate output from what the
model acts on and is known to come back in the wrong language while the model understood correctly.
- **No tool guard reads the driver's transcript.** Gemini hears the audio and its tool call (name + arguments) is the
  decision. Guards check only the call's arguments, app state and timing (driver turns counted by the uplink gate,
  F-04a). `wordsReliable` and `.wordsUnclear` are withdrawn.
- The first version of this section (unreadable words refuse allow-type guards) is withdrawn.
- Word-based guards that exist today (F-09, ported from Android) lose their transcript input as follows (T-016d):

| Guard | Today (reads transcript) | After |
|---|---|---|
| F-15a start (`navigationNotRequested`) | pick/start word list | driver-turn order only (F-15a §2.5 revised) |
| F-15a `navigate_to` | go/place word list | removed (it only lists) |
| `wordsUnclear` | unreadable words refuse | removed |
| `speechOutputNotRequested` (P66) | 别说了-type words required | removed; `set_speech_output` runs on the call |
| `vagueExitWhileNavigating` | explicit-end words required | removed, no confirmation (revised 2026-10-29, T-016e): `exit_navigation_mode` ends guidance on the call; she then says 「已结束导航」. The `CONFIRM_REQUIRED` step of T-016d is withdrawn — see the note below the table |
| `nearbyQuestionWhileNavigating` (P61) | question words | state: while navigating, `navigate_to` opens the along-route list and never replaces the route until a pick |
| `sunroofOnWindowTool` (P56) | 天窗 words | removed; the catalog description says sunroof/doors/lights/wipers are unsupported |
| `driverSideWindow` | 我这边 words | removed (T-016d): the call's window position is used as given |
| `ambiguousReferent` | relative words in the request | removed; the model asks when it is unsure |
| `unsupportedMedia` | song-name words | removed (T-016d): `control_music` has no title/artist argument to check |

- **Ending navigation (revised 2026-10-29, owner: "Update spec").** Device run ed40023: 结束导航 was refused twice
  with `CONFIRM_REQUIRED` and guidance did not end. Her question took ~17 s, so the driver's yes came 20.6 s after the
  first refusal, past the 15 s window counted from the refusal, and was treated as a new first request. Common practice
  ends navigation on the voice command at once (Google Maps / Android Auto: "Stop navigation" ends the route; only the
  touch button asks), and voice-design guidance keeps explicit yes/no questions for costly or irreversible actions;
  ending a route is reversible (say the destination again). So: no confirmation, no timer; `exit_navigation_mode`
  executes on the call (a list open or a tap is handled as before, F-15). Implicit confirmation only: the result's
  `next` makes her say 「已结束导航」. `CONFIRM_REQUIRED` stays defined but is not returned by any guard.
- **Not tool calling, kept on the transcript:** the 别说了 stop phrase (owner rule 2026-10-28, local barge-in) and the
  echo filter (F-14 §8, drops her own voice). They change no car or navigation state. They use the phone's zh-CN text.
- **Honest replies:** a refused or not-run call must not be followed by a success claim; F-09 `ActionClaimGuard`
  checks her reply against app state (F-15a §2.5).

## 7. Dependencies and external services
- `Speech` framework only in Packages/NovaAudio (`scripts/gates/check_imports.py`: add `"Speech": {"NovaAudio"}`).
  `TranscriptSelector`, `LocalTranscriber` and their tests are pure Swift in NovaCore (Linux gates).
- No network. Gemini setup unchanged (`inputAudioTranscription` stays on; it is the S3 fallback).

## 8. Error handling and recovery
- **Language check** (pure, `TranscriptLanguage.isChinese(text)`): true when ≥ 60 % of the letters are Han
  characters (CJK Unified Ideographs, incl. Ext. A) and the text has at least one Han character; digits and
  punctuation are ignored. Latin-only text (Portuguese, English) is false. PROPOSED (T-016a): a run of Latin
  letters counts as one letter (one word), so 「导航去 Costa」 is 3 of 4 = 75 % Chinese; other scripts count per character.

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
| 4 | (revised) No tool guard reads the transcript: the same tool call gives the same guard result with an empty, Portuguese or unrelated transcript; each guard in the §6 table behaves as its "After" column | unit |
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
- OQ-STT-1 **decided 2026-10-29 (owner: defaults): no**. Show the local text even while Gemini's answer is already playing for the previous turn?
  Default: the subtitle area shows the newest utterance only, as today.
- OQ-STT-2 **decided 2026-10-29: Mandarin only**. Cantonese input? Out of scope; owner rule says Mandarin. A Cantonese
  utterance is recognised as Mandarin text (possibly wrong) and Gemini still hears the audio.

## Tasks (implementation-plan.md M1 follow-up, specs/work.json)
| ID | Task | Verification |
|---|---|---|
| T-016a | `LocalTranscriber` port, `TranscriptSelector`, `TranscriptLanguage`, `GuardContext.wordsReliable` + `.wordsUnclear`; rows 1–4 | unit (Linux gates) |
| T-016b | `AppleSpeechTranscriber` (NovaAudio), import gate entry, Info.plist key, permission with first mic use | build |
| T-016c | Wire into `AgentRuntime` (frames to transcriber, selector in front of `AgentState`), 音频测试 diagnostics line; rows 5–9 | S, D |
| T-016e | §6 ending navigation: remove `confirmExit` / `exitConfirmWindow` from `ToolDispatcher`; `exit_navigation_mode` ends guidance on the call and the result's `next` says 「已结束导航」; tests: one call ends guidance whatever the transcript, no `CONFIRM_REQUIRED` ever; D: 结束导航 ends at once | unit (Linux gates), D |
| T-016d | §6 revised: remove the transcript from every tool guard (table), withdraw `wordsReliable` / `.wordsUnclear`, `CONFIRM_REQUIRED` for exit while guiding (withdrawn by T-016e), along-route list instead of P61; row 4 (revised); F-09 guard rows that read words marked superseded | unit (Linux gates) |
