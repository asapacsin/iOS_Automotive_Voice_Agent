# F-05a Mandarin input transcript on the phone (普通话识别不再被当成葡萄牙语)

**Status:** APPROVED 2026-10-29 (owner: "Approve defaults"; OQ-STT-1 no, OQ-STT-2 Mandarin only). iOS only. Owner report 2026-10-29 (device run
aba6829): "the input sometimes interpret as portugese even though that is actually mandarin". Owner chose the
on-device recognizer 2026-10-29: "Use Apple's on-device recognizer for the transcript … locked to zh-CN and ignore
Gemini's guess."
**Revised 2026-10-29:** the transcript is for display only; no tool guard reads it (§6, owner rule after run 9f48c45).
**Revised 2026-10-30:** the recognizer is a bundled sherpa-onnx streaming Mandarin model, not Apple's (§12, T-016f);
§2–§4 and §8 text about `SFSpeechRecognizer`, the 「语音识别」 permission and `AppleSpeechTranscriber` is superseded by §12.
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
- **Revised 2026-11-10 (F-09a, owner "Yes, build it"):** the comfort tools (`control_climate`, `control_window`, `control_seat`, `run_scenario`) run only when the phone recognizer's final text of the utterance falls in the car area (F-09a §2); a tired utterance is silenced in code. Gemini's transcript is still never read by a guard, and every other tool keeps the rule below.
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
| T-016b | CLOSED, replaced by T-016f (bundled recognizer; Apple Speech removed) | — |
| T-016c | CLOSED, replaced by T-016f (bundled recognizer; Apple Speech removed) | — |
| T-016e | §6 ending navigation: remove `confirmExit` / `exitConfirmWindow` from `ToolDispatcher`; `exit_navigation_mode` ends guidance on the call and the result's `next` says 「已结束导航」; tests: one call ends guidance whatever the transcript, no `CONFIRM_REQUIRED` ever; D: 结束导航 ends at once | unit (Linux gates), D |
| T-016d | §6 revised: remove the transcript from every tool guard (table), withdraw `wordsReliable` / `.wordsUnclear`, `CONFIRM_REQUIRED` for exit while guiding (withdrawn by T-016e), along-route list instead of P61; row 4 (revised); F-09 guard rows that read words marked superseded | unit (Linux gates) |

## 12. Bundled recognizer (iOS, APPROVED 2026-10-30, replaces Apple's recognizer)

**Why.** Device run 25a5cd9 (2026-10-30): 音频测试 showed 「识别：云端（本机不可用…）」. The test phone's dictation
languages are Cantonese, English (UK) and Japanese (keyboard: Traditional Chinese Cangjie). iOS downloads an on-device
speech model only for the dictation languages of the installed keyboards, so `SFSpeechRecognizer(zh-CN)` has no model,
and Mandarin (Taiwan) is not there either. The owner will not add a Pinyin or Zhuyin keyboard. Every utterance
therefore falls back to Gemini's transcript (slow, sometimes not Chinese, 「（没听清）」) and 别说了 is not caught on the
phone. Owner 2026-10-30 after the comparison (Apple / iFlytek cloud / bundled model; sherpa-onnx vs Whisper): "Yes,
write spec".

**Rule in plain words.** The app carries its own Mandarin speech model and uses it on every iPhone, whatever keyboards
or languages the phone has. Nothing is downloaded at run time and no audio leaves the phone.

1. **Engine.** [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) `OnlineRecognizer` with a
   **streaming** Mandarin model (streaming Zipformer or streaming Paraformer, int8). Not Whisper: it is not streaming
   (text in chunks, ~0.5–1.5 s) and it is multilingual (wrong-language output is the problem being fixed).
2. **Model choice (T-016f picks it and records it in STATUS.md).** Trained for Mandarin (zh-CN); streaming; all model
   files together ≤ 80 MB; licence allows use in this app (record it); Simplified or Traditional output is fine
   (matching code folds both). Pick the smallest model that meets rows 5 and 9 on the test phone; a mixed zh/en model
   is allowed if it meets row 5.
3. **Bundled, not committed.** The model files are app bundle resources, **not** stored in git. The build fetches them
   from a pinned sherpa-onnx release URL and checks a SHA-256 kept in the repo (a script under `scripts/`, run by the
   existing manual Codemagic workflow and by local builds; no new CI trigger, owner rule 2026-10-27). A wrong checksum
   fails the build.
4. **Adapter package.** New package `Packages/NovaAsrSherpa` (vendor SDK in its own adapter, ios-architecture §3.2):
   the sherpa-onnx and onnxruntime xcframeworks as SwiftPM `binaryTarget`s, and `SherpaTranscriber: LocalTranscriber`.
   Add the sherpa module to `OWNERS` in `scripts/gates/check_imports.py` (NovaAsrSherpa only) and the row to the §3.2
   table. NovaCore is unchanged: `LocalTranscriber` and `TranscriptSelector` (§4, §5) stay as they are.
5. **Utterances come from the gate.** One recognizer stream per utterance: `begin` creates it, `append` feeds the same
   16 kHz mono frames the uplink gate passes (as float samples), `end` marks input finished, decodes the rest and emits
   the final. sherpa-onnx's own endpoint detection is off; the uplink gate (F-04) decides where an utterance starts and
   ends. A partial is emitted whenever the decoded text changes.
6. **Utterances not sent to Gemini are still recognised.** Utterances F-04 §14 does not send (she is talking) are still
   fed to the recognizer, so 别说了 is caught on the phone while she talks (F-04 §14 item 5).
7. **Load once.** The model loads off the main actor when the app starts (or at the first session, if simpler), once per
   app run, and stays loaded. Until then availability is `.unavailable(reason: 模型加载中)` and §5 S3 applies.
8. **Apple's recognizer is removed.** Delete `AppleSpeechTranscriber`, its `Speech` import and `OWNERS` entry, the
   `SFSpeechRecognizer.requestAuthorization` call and `NSSpeechRecognitionUsageDescription` (App/project.yml,
   App/xtool-Info.plist). No 「语音识别」 permission popup any more; the microphone permission is unchanged.
9. **Fallback unchanged.** If the model fails to load or a stream fails, §5 S3 (Gemini transcript with the language
   check) applies, as today.
10. **Diagnostics.** 音频测试 line: `识别：本机（内置 <model short name>）` when ready, otherwise
    `识别：云端（本机不可用：模型加载中 | 模型加载失败）`. Log (`RuntimeLog.agent`, numbers only, I-8: never the text): one
    line at load `asrLoaded model=<name> ms=<load time>`; one per utterance `asrUtterance id firstPartialMs finalMs audioMs decodeMs`.
11. **Load on the phone.** Decode only while an utterance is open (as today). Real-time factor (decodeMs / audioMs)
    ≤ 0.3 on the test phone.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `SherpaTranscriber` fed a recorded Mandarin utterance (fixture PCM) through begin / append / end | Partials, then one final, all tagged with the utterance id; the final has the expected words | unit (macOS build) or S |
| 2 | Events of a closed or superseded utterance | Dropped (§9) | unit |
| 3 | Build with a wrong model checksum | Build fails with a clear message | build |
| 4 | Import gate | Only NovaAsrSherpa imports the sherpa module; nothing imports `Speech` | gate |
| 5 | Test phone as it is (Cangjie keyboard; dictation Cantonese / English / Japanese) | 音频测试 shows 「识别：本机（内置 …）」; no 「语音识别」 popup; the 30 short commands of §10 row 5: ≥ 27/30 correct, all Chinese | D |
| 6 | Airplane mode | Subtitles still appear | D |
| 7 | 别说了 while she talks (utterance not sent to Gemini) | Caught from the local partial; she stops at once | D |
| 8 | Phone log during rows 5–7 | No transcript text; `asrLoaded` and `asrUtterance` lines present | D |
| 9 | Latency on the test phone | First partial ≤ 500 ms after speech starts; final ≤ 300 ms after the utterance ends; RTF ≤ 0.3 | D (log lines) |
| 10 | IPA size | Grows by the model size only (≤ ~90 MB in total) | build |

§10 rows 5, 6 and 9 are checked through rows 5, 6 and 9 here; §10 row 7 (speech permission denied) is withdrawn.

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-016f | §12 items 1–11: NovaAsrSherpa package (xcframeworks, `SherpaTranscriber`); model pick and pinned fetch with checksum; wiring in `AgentRuntime` in place of `AppleSpeechTranscriber`; remove Apple's recognizer and permission; diagnostics and log lines; import gate and §3.2 row | unit, gate, build, D (rows 5–10) |

## 13. Only Chinese reaches the conversation text on screen (iOS, APPROVED 2026-11-05)

**Why.** Owner 2026-11-05: the screen sometimes shows Korean or other languages; force it to Chinese. Records `20261104-*` and `20261105-*` (8 files) contain no Korean, and they do not record what was on screen, so the Korean itself is not traced. They do show Gemini returning Spanish and Hindi, and a Spanish reply 「Disculpa…」 caught by the reply guard. Reading the code at 21f4478 shows four ways other text can still reach the screen:

| Path | Gap |
|---|---|
| Her reply (`ReplyLanguage.isNotMandarin`) | The reply is voided only at 6 letters with no Han, so up to 5 letters can show first, and 5 Korean syllables are a visible word. One Han character passes the whole reply, so mixed text is never caught. |
| A guidance reading (`AgentState`, `relayTurns`) | Added to the subtitle with no language check |
| The driver's line from the local recognizer (`TranscriptSelector`, S1) | Shown with no language check; only Gemini's fallback text is checked |
| The camera answer (`tapAsk`, `cameraAnswer`) | Shown with no language check |

Code can guarantee what is shown. It cannot guarantee what Gemini hears or writes.

**Rule in plain words.** All conversation text passes one check just before it is shown. Text that fails is not shown.

1. **One pure check.** `ScreenLanguage` in `NovaVoice/Transcript`, with no UI imports. It takes the text and whether it is final, and returns `show`, `wait` or `hide`:
   - Any letter in a script other than Han or Latin (Hangul, Kana, Cyrillic, Devanagari, Arabic, Thai and so on) → `hide`, even inside a Chinese sentence.
   - No letters (`22`, `…`) → `show`.
   - Has Han and passes `TranscriptLanguage.isChinese` → `show`. A name inside a Chinese sentence stays (「导航去 Costa」, 「4S店」).
   - Has Han and fails `isChinese`: not final → `wait`; final → `hide`.
   - No Han, only Latin: not final → `wait`. Final → `show` only for at most 5 characters of `A-Z` and `0-9` (`OK`, `4S`); otherwise `hide` (`What?`, `¿Qué?`).
2. **Where it applies.** At the last step before each of these is published, and on the whole text so far, not on each new piece:
   - **The driver's line** (`driverLine`), from any source. `hide` shows 「（没听清）」.
   - **Her reply** (`view.subtitle`). `wait` shows nothing yet, and the text appears whole once it passes. `hide` shows nothing.
   - **A guidance reading.** `hide` shows the engine's own guidance text instead. Her voice for guidance is not changed (F-14).
   - **The camera answer** (`cameraAnswer` and the subtitle). `hide` shows and speaks the existing 「刚才没看清楚，再问我一次吧。」 instead.
3. **Display only.** The check never changes what the guards, the stop phrase, the echo filter or the tools read (§6). A hidden driver line can still be 「别说了」 for the stop-phrase path.
4. **Her voice follows for other scripts.** `ReplyLanguage.isNotMandarin` also returns true as soon as the reply has a letter from a script other than Han or Latin, so that reply is voided with `NOT_MANDARIN` as today, not spoken and then hidden. The 6-letter Latin rule is unchanged.
5. **Seeing what happened.** Record line `screen-hidden kind=<driver|reply|guidance|camera> text=<first 80 characters>`, so the next case can be traced. `RuntimeLog` gets only `screenHidden kind=<...>`, with no words (I-8).
6. **What this does not cover.**
   - Map labels drawn by the map SDK, and iOS system alerts and permission text.
   - Fixed labels and product names: `Nova Drive`, `Gemini`, `AGC`, and error codes in 「连接错误：…」.
   - Place names and addresses from Amap in the lists, which are shown as Amap returns them.
   - Developer pages: recorder, audio test and comfort evaluation.
   - Mishearing. A wrong Chinese sentence still shows, because it is Chinese.
7. **Not changed.** The input audio, the Gemini setup, the `NOT_MANDARIN` correction text, and the rule that the local recognizer's text wins over Gemini's.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Final: 「你好」, 「导航去 Costa」, 「4S店」, `OK`, `4S`, `22` | `show` | unit |
| 2 | Final: 「안녕하세요」, 「好的안녕」, 「こんにちは」, 「Привет」, 「मैं」, `¿Qué?`, `What?`, `la vecina` | `hide` | unit |
| 3 | Not final: `Disc`, `OK`; 「안」; 「你好」 | `wait`, `wait`; `hide`; `show` | unit |
| 4 | Reply pieces `OK`, `，好的` | Nothing shows after the first piece; 「OK，好的」 shows whole after the second | unit |
| 5 | Reply 「안녕」 | Voided with `NOT_MANDARIN` at the first Hangul letter; nothing published, nothing spoken | unit |
| 6 | Reply in Spanish, piece by piece | Nothing shows at any point; voided at 6 letters as today | unit |
| 7 | Local recognizer text and Gemini fallback text, each `la vecina` | The driver's line shows 「（没听清）」; guards and the stop phrase receive the same words as before | unit |
| 8 | A hidden guidance reading; a hidden camera answer | The engine's guidance text shows and her guidance voice is unchanged; the fallback sentence shows and is spoken | unit |
| 9 | Each hidden kind | One `screen-hidden` record line; the log line has no words | unit |
| 10 | Device, record on: normal use for a day, including noise and short words such as 「什么」 | No Korean, Spanish or other script in the bubbles. If any shows, take a screenshot with the time and compare with `screen-hidden` | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-016i | Items 1–7; rows 1–10 | unit, build, D |

## 14. Chinese, English and Japanese: a downloaded SenseVoice model gives the final line (iOS, APPROVED 2026-11-09)

**Why.** Owner 2026-11-09: the driver sometimes speaks English or Japanese, and the app only handles Chinese. The model must not make the app package bigger; it is installed after the app, as a download. At 212f52d, Chinese is fixed in five places:
- The local recognizer (§12) is `zipformer-small-ctc-zh-int8-2025-04-01`, Chinese only, and its text wins (§5 S1). English comes out as Chinese nonsense: record 20261109-180202 has 「先稍一烧珠海」.
- `ScreenLanguage` (§13) hides Kana and Latin sentences as 「（没听清）」.
- `ReplyLanguage.isNotMandarin` (§13 item 4) voids English and Japanese replies as `NOT_MANDARIN`.
- The Gemini setup sends `speechConfig.languageCode = "zh-CN"` (`RealtimeConfig`, `GeminiRecorder`).
- The persona says 「用自然的普通话口语」 and 「只说普通话」.

**Sources (2026-11-09).**
- **Detect the language, then use the matching recognizer.** Google Assistant's two-language mode runs a language-ID model on incoming speech and a recognizer per language in parallel, then answers in the language asked ([TechRadar](https://www.techradar.com/news/you-can-now-talk-to-google-assistant-in-two-languages-at-once), [VentureBeat](https://venturebeat.com/ai/google-assistant-can-now-speak-two-languages-at-once)). Alexa's multilingual mode answers in the language asked ([Voicebot](https://voicebot.ai/?p=16060)).
- **One on-device model for all three.** sherpa-onnx's SenseVoice (Chinese, English, Japanese, Korean, Cantonese, with auto-detect) is listed with a VAD + recognition demo ([sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/), [pretrained models](https://k2-fsa.github.io/sherpa/onnx/pretrained_models)). It is offline (whole utterance), not streaming. No single streaming model with all three was found; the streaming zh-en zipformer has no Japanese.
- **Our build already has it.** The bundled sherpa-onnx v1.12.21 header (`CSherpaOnnx/include/c-api.h`) has `SherpaOnnxOfflineSenseVoiceModelConfig` (`model`, `language`, `use_itn`) and the offline result's `lang`.
- **Download after install.** Apps that use large speech models download them on first use (WhisperKit from Hugging Face; sherpa-onnx apps). On-Demand Resources and Apple-hosted Background Assets need App Store or TestFlight hosting; this app is installed with xtool, so it downloads with `URLSession`.
- **Gemini picks the language itself.** Google's Live API docs: native audio models switch language during a conversation, languages are limited in the system instruction, and `speech_config.language_code` is for non-native-audio models ([configure language and voice](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/live-api/configure-language-voice)).
- **Checked on the PC, 2026-11-09.** Hugging Face `csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17`, revision `2365baeacb507f821a0c8120fcee3d484dba7a07`, converted from FunAudioLLM/SenseVoice: `model.int8.onnx` 239,233,841 bytes, SHA-256 `c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51`; `tokens.txt` 315,894 bytes, SHA-256 `f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc`. Its LICENSE refers to the FunASR licence. The newer `…-int8-2025-09-09` package is a Cantonese fine-tune (WSYue-ASR) and is not used. `hf-mirror.com` answered for the same paths.

**Rule in plain words.** The live text while the driver speaks stays the streaming Chinese model. When the utterance ends, a downloaded SenseVoice model gives the final line in Chinese, English or Japanese. The screen shows those three languages and hides the rest. She answers in the language the driver used. Until the model is downloaded, everything works as it does now.

1. **The download.**
   - 设置 → 「语音识别」 gets a switch 「多语言识别（中文 / English / 日本語）」, on by default, with the state under it: 「未下载（约 240 MB）」, 「下载中 n%」, 「已就绪」, 「下载失败，点按重试」.
   - When the switch is on and the model is missing, the download starts by itself on Wi-Fi only (`allowsExpensiveNetworkAccess = false`, `allowsConstrainedNetworkAccess = false`). A 「用流量下载」 button starts it on any network.
   - Files: §14 Sources' `model.int8.onnx` and `tokens.txt`, from `https://huggingface.co/<repo>/resolve/<revision>/<file>`; if that fails or times out, the same path on `https://hf-mirror.com`. The repo, revision, sizes and SHA-256 are constants in the code.
   - A background `URLSession` download, resumed after the app is suspended or relaunched. Files land in a temporary place, are checked against their SHA-256 and size, then moved to `Application Support/SpeechModels/sensevoice-2024-07-17/` with `isExcludedFromBackup`. A wrong checksum deletes the file; the state becomes 「下载失败，点按重试」. Nothing that fails the check is ever loaded.
   - A model that passed the check stays across app updates and reinstalls over the same app, and is not downloaded again. 设置 has 「删除多语言模型」. Turning the switch off unloads the model and keeps the files.
   - Audio never leaves the phone. Only the model files are downloaded. This replaces §12's 「Nothing is downloaded at run time」 for this model only; the streaming model, the keyword spotter and the speaker model stay in the app package.
2. **Recognition.**
   - The streaming Chinese recognizer runs as now and gives the live partials (§5 S1) and the local stop-phrase path.
   - When the model is ready, `NovaAsrSherpa` also keeps the utterance's 16 kHz samples (the same frames the gate passes, up to 30 s) and, at `end`, runs a SenseVoice `OfflineRecognizer` once (`language` empty = auto, `use_itn` 1, on a background queue). Its `text` and `lang` become the utterance's final.
   - The final of an utterance is SenseVoice's when it arrives within §5 S2's `localFinalWait` (800 ms after the end). Otherwise the streaming model's final is used, as now. Either way, it is one final per utterance.
   - `lang` is mapped: `zh` and `yue` → zh, `en` → en, `ja` → ja, anything else (`ko`, empty) → other. SenseVoice's tags (`<|zh|>`, emotion and event tags) never reach the text.
   - `LocalTranscript`'s final gains `language` (`zh`, `en`, `ja`, `other`, or nil for the streaming model). `TranscriptSelector` keeps S1–S5.
   - The model is loaded when the switch is on and the files are ready, once per app run, before the first session if possible. A load failure falls back to the streaming final, with the state 「加载失败」.
3. **The screen (§13 item 1 changes).**
   - `ScreenLanguage` allows Han, Kana (Hiragana, Katakana) and Latin. Hangul, Cyrillic, Devanagari, Arabic, Thai and other scripts are still `hide`.
   - A final Latin-only line is `show` when the utterance's `language` is en (any length). Without that, the 5-character rule stays.
   - A line with Kana is `show` when final. Not final, it is `wait`.
   - Her reply: Latin-only and Kana text follows the same rules, with the reply's language taken from the text (Kana → ja; Latin letters with no Han → en).
4. **Her language.**
   - `RealtimeConfig` stops sending `speechConfig.languageCode`, and `GeminiRecorder` likewise. If `gemini-3.8-live` rejects a setup without it, keep `"zh-CN"`, record that in STATUS, and rely on the system instruction.
   - Persona: 「用自然的普通话口语」 becomes 「用自然的口语」, and 「只说普通话。」 becomes 「用户说中文就用普通话回答，说英文就用英文，说日语就用日语；只用这三种语言。」.
   - `ReplyLanguage.isNotMandarin` becomes `isNotAllowed`: true as soon as the reply has a letter from a script other than Han, Kana or Latin. The 6-letter Latin rule is removed. The `NOT_MANDARIN` code and correction text stay for those other scripts.
5. **Logs.** The record's `heard-local` line gains `lang=<zh|en|ja|other|stream>` and `asr=<sensevoice|stream>`, and `asr-model state=<…>` when the state changes. `RuntimeLog`: `asrMulti state=<…> ms=<decode ms>`, with no words (I-8).
6. **Where the code goes.**
   - NovaCore: `ScreenLanguage`, `ReplyLanguage`, the `lang` mapping, `LocalTranscript`'s `language`, and the download state machine (pure: states, checksums and URLs come in as values).
   - NovaAsrSherpa: the SenseVoice `OfflineRecognizer` and the sample buffer.
   - App: the `URLSession` downloader, the files, and the 设置 rows.
   - NovaRealtime: the `languageCode` removal.
   - Persona text in `SpeakingStyle`.
7. **Not changed.**
   - The streaming Chinese model, the keyword spotter (stop phrases stay Chinese) and the speaker lock.
   - §6 (no tool reads the transcript).
   - Gemini's input transcript as the S3 fallback.
   - Navigation guidance stays Chinese (F-14). The Qwen voice, when chosen, read whatever language she answers in.

**Not verified.**
- SenseVoice's decode time on the test phone; it must fit the 800 ms wait (row 9).
- Download speed and reachability of huggingface.co and hf-mirror.com from the phone's network (row 8).
- Whether `gemini-3.8-live` accepts a setup without `languageCode` (row 10).
- The FunASR licence terms for this app; T-016l records them in STATUS.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Download state machine: missing → Wi-Fi → progress → files with the right SHA-256; a wrong SHA-256; Hugging Face fails | Ready, files in the model folder; file deleted, 「下载失败，点按重试」, nothing loaded; same path on hf-mirror.com tried | unit |
| 2 | Not on Wi-Fi, switch on, no tap | No download; 「用流量下载」 starts it | unit |
| 3 | SenseVoice result `lang` `zh`, `yue`, `en`, `ja`, `ko`, empty; text with `<|en|><|NEUTRAL|>` tags | zh, zh, en, ja, other, other; tags removed | unit |
| 4 | Selector: SenseVoice final at 500 ms; at 1,200 ms; model not ready | SenseVoice text is the final; the streaming final is used and the late one is dropped; streaming final as now | unit |
| 5 | `ScreenLanguage` final: 「What's the weather in Tokyo」 with language en; same with no language; 「東京の天気は」; 「안녕하세요」; 「Привет」 | show; hide; show; hide; hide | unit |
| 6 | `isNotAllowed`: 「Sure, it's 22 degrees」; 「はい、22度です」; 「안녕하세요」; 「Disculpa」 | false; false; true; false | unit |
| 7 | Gemini setup JSON; persona text | No `languageCode`; persona texts exactly as item 4 | unit |
| 8 | Device, Wi-Fi: fresh install, switch on | Download completes, 「已就绪」, files survive the next xtool install; record has `asr-model state=ready` | D |
| 9 | Device: say "What's the weather in Tokyo now?", 「東京の天気はどうですか」, 「现在几点」 | Screen shows each sentence in its language; `heard-local … asr=sensevoice lang=en/ja/zh`; decode ms in `RuntimeLog` under 800 | D |
| 10 | Device: same three | She answers in English, Japanese and Chinese; no `NOT_MANDARIN`; the session connects without `languageCode` | D |
| 11 | Device: switch off; then 「删除多语言模型」 | Chinese only as before; files removed, state 「未下载」 | D |

**Trace gate.** Add `T-016l: F-05a` to `specs/trace-ids.txt` together with the first `@Test` that names T-016l.

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-016l | Items 1–7; rows 1–11 | unit, build, D |

## 15. Her reply is checked for its language in code before she says it (iOS, owner request 2026-11-10)

**Why.** Device 2026-11-10, build 53 (a5a03f9), record 20261110-090143. The owner allowed Chinese, English and Japanese only (§14), but she answered in Portuguese twice.
- **Utterance 7 (+53,474).**
  - SenseVoice heard it correctly: `heard-local 不知道。 lang=zh asr=sensevoice`.
  - Gemini heard `tudo bem` and answered 「Tudo bem, em que posso ajudar você?」, which was played in full.
- **Utterance 9 (+81,656).** `heard-local 不. lang=en`; Gemini heard `Jardin` and answered 「Você gostaria de encontrar algum jardim?」.
- **Utterance 11 (+136,515).**
  - `heard-local 早安。 lang=zh`; Gemini heard 「당연하죠.早上。」.
  - Her Korean reply played 14 ms (`claim-cut turn=8 played_ms=14`), then was voided with `NOT_MANDARIN`.
  - Her next reply, 「早上好，请问有什么可以帮您的？」, was voided too (`reply-out turn=9 voided`), so the owner heard no answer.
- **Short words, low voice match.** All three were one or two words, with speaker scores 1.96, 0.96 and 5.7 (the owner's usual score is about 8).
- **The cause in code.** `ReplyLanguage.isNotAllowed` (§14 item 4) looks only at the script. Every Latin letter passes, so Portuguese, Spanish and French pass as English. `ScreenLanguage.replyLanguage` calls any Latin-only reply `en`.
- **Owner:** 「isn't i said that only chinese, japanese and english available」, then asked for the community practice, then 「write this spec」.

**Sources (2026-11-10).**
- **The prompt alone does not hold the language.**
  - Google's [Live API troubleshooting](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/live-api/troubleshooting) says the model may answer in another language when it decides the user spoke one. A language rule in the system instruction only lowers the chance.
  - Native-audio models take no `languageCode` ([configure language and voice](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/live-api/configure-language-voice)); setting one fails with "Unsupported language code" ([forum](https://discuss.ai.google.dev/t/gemini-live-api-error-unsupported-language-code-es-es/114284)).
  - Developers report Gemini Live answering or transcribing in a wrong language with explicit instructions in place ([forum](https://discuss.ai.google.dev/t/why-is-gemini-api-transcribing-english-into-other-languages/113934), [livekit/agents #3551](https://github.com/livekit/agents/issues/3551)).
- **Check the output's language in code.**
  - Guardrails AI's [CorrectLanguage validator](https://github.com/scb-10x/correct_language_validator) runs a language detector on every LLM output and fails it when it is not the expected language.
  - [phantombot #580](https://github.com/phantomyard/phantombot/issues/580) found that more copies of the reply-language rule in the prompt made it worse, and chose a deterministic check on the output.
- **On a failed check, ask again once, then fall back.**
  - Guardrails AI's [on-fail actions](https://guardrailsai.com/docs/concepts/validator_on_fail_actions) include `reask`: the model is asked again with the reason it failed; the how-to sets `num_reasks=1`.
  - Hugging Face [speech-to-speech](https://github.com/huggingface/speech-to-speech): a reply that cannot be spoken in the detected language uses the session's set language.
- **The detector is in iOS.** Apple's [`NLLanguageRecognizer`](https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer) (Natural Language framework, on device, no download) gives the dominant language and `languageHypotheses(withMaximum:)` with probabilities.
- **Not from a source.** Putting SenseVoice's words into the re-ask (item 4) is this app's addition, because here the wrong language comes from Gemini mishearing words that SenseVoice heard correctly.

**Rule in plain words.** Before she says a reply, the app checks its language with Apple's detector. If it is not Chinese, English or Japanese, the reply is dropped. She is asked once more, with the words SenseVoice heard. If that reply is also wrong, or does not come, the app itself says 「没听清，请再说一遍」. It never relies on the prompt alone, and it never leaves the driver with silence.

1. **The detector.**
   - A port `LanguageIdentifier` in NovaPorts: `func hypotheses(_ text: String) -> [(language: String, probability: Double)]`, at most 3, BCP-47 codes.
   - The adapter `AppleLanguageIdentifier` in NovaPlatform uses `NLLanguageRecognizer`: a new recognizer per call or `reset()` before each, `processString`, then `languageHypotheses(withMaximum: 3)`. No `languageConstraints`, so other languages are reported as themselves. `check_imports.py` gets `"NaturalLanguage": {"NovaPlatform"}`.
   - The pipeline gets it injected, so NovaCore stays pure and the tests use a fake.
2. **The verdict on her text so far** (pure `ReplyLanguageCheck` in NovaVoice, replacing the Latin pass of `isNotAllowed`), one of `allowed`, `blocked`, `undecided`:
   - **Other scripts.** A letter of a script other than Han, Kana or Latin gives `blocked` at once, as today.
   - **Chinese or Japanese.** Two or more Han or Kana letters give `allowed`. Latin words inside a Chinese or Japanese reply are allowed (「4S店」, 「OK，好的」).
   - **Latin-only, 12 or more letters.**
     - `blocked` when the detector's top hypothesis is not `en` with probability ≥ 0.5;
     - `allowed` when it is `en` with probability ≥ 0.5;
     - `undecided` otherwise.
   - **Latin-only, under 12 letters, still coming:** `undecided`.
   - **At the end of the reply** (`audioDone`), anything `undecided`:
     - Latin-only under 12 letters is `blocked` only when the detector's top hypothesis is not `en` with probability ≥ 0.8, and is otherwise `allowed` (「OK」, 「Sure」);
     - any other `undecided` text is `allowed`.
   - Once `allowed` or `blocked`, a turn's verdict does not change, except that `allowed` text that later gains a letter of another script becomes `blocked`, as today.
3. **Audio waits for the verdict.**
   - In every turn, her first audio is held until the verdict is `allowed`, for at most 800 ms after the first audio arrives. Today's claim hold (`holdsWhole`) is unchanged and still applies on top.
   - At 800 ms with no verdict, the audio is released and the check goes on. A later `blocked` cuts her as today (`claim-cut`).
   - `blocked` drops all held audio and text and voids the turn (`.voided`). Nothing of it is shown or spoken.
   - With the Qwen voice (F-07), the text is checked before it is sent to the voice. The same rules apply, with no audio to hold.
4. **One re-ask** (Guardrails `reask`, `num_reasks=1`).
   - On the first `blocked` reply of an utterance, the app sends one text turn. `CorrectionReason.notMandarin` is replaced by `.wrongLanguage` (`WRONG_LANGUAGE`), sent at once, not after the correction grace:
     - when the utterance has a SenseVoice final with `lang` zh, en or ja: 「[系统] WRONG_LANGUAGE：刚才的回答不是中文、英文或日语，已作废。司机刚才说的是「<SenseVoice 文字>」。请用<中文|英文|日语>回答这句话。」;
     - otherwise: 「[系统] WRONG_LANGUAGE：刚才的回答不是中文、英文或日语，已作废。请用中文简短地请司机再说一遍。」.
   - The SenseVoice words go to the model only in this text turn. No tool reads them (§6 unchanged).
   - The re-ask's reply goes through items 2–3 again.
5. **The fallback line.**
   - If the re-ask's reply is also `blocked`, or no reply audio or text comes within 6 s of the re-ask, the app says 「没听清，请再说一遍」 itself, with the system voice that F-14 guidance already uses (`SystemSpeechGuidanceVoice`, zh-CN), on the guidance lane.
   - It is said at most once per utterance. A new driver utterance cancels it.
   - The subtitle shows it as her line.
6. **Screen.** `ScreenLanguage.replyLanguage` uses the item 2 verdict: a Latin-only reply is `en` only when `allowed`. A `blocked` reply is never shown.
7. **Record and log** (no words, I-8):
   - `lang-check turn=<n> verdict=<allowed|blocked|released> lang=<code|none> p=<0.00> held_ms=<n>`, once per turn when the verdict is reached, or `released` at the 800 ms limit;
   - `correction WRONG_LANGUAGE heard=<sensevoice|none>`;
   - `fallback-line turn=<n> reason=<blocked_again|no_reply>`.
8. **Where the code goes.**
   - NovaPorts: `LanguageIdentifier`.
   - NovaVoice: `ReplyLanguageCheck`, the hold in `DriverTurnPipeline`, `.wrongLanguage`, and the fallback timer and output.
   - NovaAgent: the record lines.
   - NovaPlatform: `AppleLanguageIdentifier`.
   - App: wiring the identifier and playing the fallback line with `SystemSpeechGuidanceVoice`.
9. **Not changed.**
   - The persona text (§14 item 4); phantombot #580 found more prompt copies made it worse.
   - SenseVoice and the screen rules for the driver's line (§13, §14 item 3).
   - No `languageCode`.
   - The claim and evidence guards.
   - The speaker check.

**Not verified.**
- `NLLanguageRecognizer`'s answers on the record's sentences and on short English replies. Rows 1–6 use a fake; row 11 checks the real one on the phone.
- How much the 800 ms hold adds to the first sound in normal turns (row 12).

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `ReplyLanguageCheck` with a fake detector: 「现在是上午九点零一分。」; 「はい、22度です」; 「안녕하세요」; 「4S店」; 「OK，好的」 | allowed; allowed; blocked; allowed; allowed | unit |
| 2 | Latin-only, fake detector: 「Tudo bem, em que posso ajudar você?」 → pt 0.9; 「Sure, it's 22 degrees now」 → en 0.9; 「Disculpa, no entendí」 → es 0.8; 12+ letters with en 0.4 | blocked; allowed; blocked; undecided | unit |
| 3 | Final, under 12 letters: 「OK」 → en 0.3; 「Sure」 → en 0.9; 「Jardin」 → fr 0.85; 「Tudo bem」 → pt 0.6 | allowed; allowed; blocked; allowed | unit |
| 4 | Pipeline: Portuguese text after 200 ms of audio | No audio released; `.voided`; one `WRONG_LANGUAGE` text turn with the SenseVoice words and 中文 | unit |
| 5 | Pipeline: Chinese text arrives 300 ms after the first audio; no text for 800 ms | Audio released when allowed; released at 800 ms with `lang-check … verdict=released` | unit |
| 6 | Pipeline: re-ask reply blocked again; re-ask with no reply for 6 s; a new utterance before 6 s | Fallback line once; fallback line once; no fallback line | unit |
| 7 | Re-ask text: SenseVoice final 「不知道。」 lang zh; lang en 「What time is it」; no SenseVoice final | Item 4 texts exactly | unit |
| 8 | Record lines | Exactly as item 7; no reply or driver words in them | unit |
| 9 | Gates | `NaturalLanguage` only in NovaPlatform; gates green | gate |
| 10 | App build | Builds on Codemagic | build |
| 11 | Device: the owner says 「Tudo bem, obrigado」, then 「Hola, ¿cómo estás?」, then 「现在几点」, 「What time is it」, 「今何時ですか」 | No Portuguese or Spanish reply is heard or shown; each of the first two gets a Chinese answer or 「没听清，请再说一遍」; the last three are answered in their language; record has `lang-check` lines with the real `lang` and `p` | D |
| 12 | Device: ten ordinary Chinese questions | Every one answered; `lang-check` `held_ms` under 800; no `fallback-line` | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-016m | Items 1–9; rows 1–12 | unit, gate, build, D |

**Trace gate.** Add `T-016m: F-05a` to `specs/trace-ids.txt` together with the first `@Test` that names T-016m.

## 16. The driver's line on screen comes from Gemini's text only, filtered to Chinese, English and Japanese (iOS, owner choice 2026-11-10)

**Why.** Owner 2026-11-10, after §15:
- **The ask.** Show only Chinese, English and Japanese on screen.
- **SenseVoice has two more.** It also recognises Korean and Cantonese (`sense-voice-zh-en-ja-ko-yue`), and no recogniser takes a list of allowed languages. VRCC [#57](https://github.com/dljr-github/VRCC/pull/57) found that forcing SenseVoice's language does not always hold, and drops out-of-set results. voicebox [#16](https://github.com/mosa-99/voicebox/pull/16) decodes once per allowed language, which on this phone (114–292 ms per SenseVoice decode, syslog 20261110-091600) would take up to about 880 ms.
- **The owner's choice.** Asked whether Gemini's own text could be used instead, the owner chose 「Gemini text only + filter」, knowing the costs below.

**Rule in plain words.** The driver's line on screen is Gemini's input transcript, checked for its language. Chinese, English and Japanese show; anything else shows 「（没听清）」. SenseVoice is removed, with its download. The phone's streaming Chinese model stays, but only for the stop phrase and the other internal uses it had before §14. Its text is never shown.

**Known costs (accepted by the owner).**
- **Later on screen.** The line appears when Gemini's text arrives. In record 20261110-090143 that was 1.3–3.6 s after the utterance ended, against 0.1–0.6 s for the local text.
- **More 「（没听清）」.** When Gemini mishears into another language, the line is hidden. Today the local text would have shown, as in 「不知道」 versus `tudo bem`.
- **The §15 re-ask loses the heard words.** §15 item 4's first text needs SenseVoice's words, so only the second text is left (item 5).

1. **Source of the driver's line.**
   - `driverLine` partials and final come from Gemini's `inputTranscription` only, for every utterance.
   - `TranscriptSelector` S1–S3 no longer pick the screen text. The local text is never published to `driverLine`.
   - An utterance with no Gemini text shows no line, as S5 does today for empty text.
2. **The filter** (`ScreenLanguage`, §13 and §14 item 3), on the whole text so far:
   - **Han and Kana.** Han that passes `isChinese` or the short-token rule, and text with Kana when final, show as today.
   - **Other scripts.** Any letter of another script hides the line, as today.
   - **Latin-only, final.** It is shown when:
     - the §15 detector (`LanguageIdentifier`) gives `en` as the top hypothesis with probability ≥ 0.5; or
     - it is a short token of at most 5 `A-Z`/`0-9` characters (`OK`, `4S`), as today.

     Otherwise it is hidden.
   - **Latin-only, not final:** `wait`.
   - A hidden final shows 「（没听清）」 and writes the existing `screen-hidden kind=driver` line.
   - The `language` argument from SenseVoice is removed; the detector replaces it.
3. **SenseVoice removed.**
   - Remove:
     - the 「多语言识别」 switch, its states, 「用流量下载」 and 「删除多语言模型」;
     - the background downloader (`MultilingualModelStore` and its background-session handler);
     - the SenseVoice `OfflineRecognizer` and its sample buffer in NovaAsrSherpa;
     - the `asrMulti` log lines and the `asr-model` record line.
   - On the first launch of this version, delete `Application Support/SpeechModels/sensevoice-2024-07-17/` and any partial download, to free about 240 MB. Do this once, in the background, and write `asr-model removed bytes=<n>` to the next record.
   - `LocalTranscript.language` and the `lang` mapping are removed. The record's `heard-local` line keeps the words, with `asr=stream` and no `lang`.
4. **The local streaming model stays, for internal use only.** It is `zipformer-small-ctc-zh-int8`, bundled, unchanged. These read its text as before §14:
   - the stop-phrase backup (F-08 §14 item 5);
   - the echo filter (F-14 §8);
   - `DriverTurnPipeline.driverUtterance` (its request words and `phantomMinTranscript`).

   The keyword spotter and the speaker check are unchanged. §6 is unchanged: no tool reads any transcript.
5. **§15 item 4, the re-ask.** It always uses the second text: 「[系统] WRONG_LANGUAGE：刚才的回答不是中文、英文或日语，已作废。请用中文简短地请司机再说一遍。」. The record line is `correction WRONG_LANGUAGE heard=none`. §15 row 7 becomes: any utterance → that text exactly. The rest of §15 is unchanged.
6. **Her reply.** Unchanged: §15 checks it. The persona's language rule (§14 item 4) stays.
7. **Where the code goes.**
   - NovaVoice: the `ScreenLanguage` Latin rule with the detector, and the driver-line source.
   - NovaAgent: `AgentState` publishes `driverLine` from Gemini's text only; the record lines.
   - NovaAsrSherpa: the SenseVoice removal.
   - App: the 设置 rows, the downloader and the one-time file removal.
8. **Not changed.**
   - Gemini setup: no `languageCode`.
   - The stop phrase, the echo filter, the speaker check and the keyword spotter.
   - §13 for her reply, guidance and the camera answer.
   - §15 except item 4.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | An utterance with local final 「不知道。」 and Gemini text `tudo bem` (detector pt 0.9) | `driverLine` shows 「（没听清）」; never 「不知道。」; one `screen-hidden kind=driver` | unit |
| 2 | Gemini text 「现在几点?」; 「今何時ですか」; `What time is it now` (en 0.9); `OK` (en 0.3); 「당연하죠.早上。」 | show; show; show; show; 「（没听清）」 | unit |
| 3 | Gemini partials `Wha`, `What time` then final (en 0.9) | Nothing shown for the partials; the final shows | unit |
| 4 | An utterance with local text and no Gemini text | No driver line; the stop phrase and `driverUtterance` still get the local text | unit |
| 5 | The local text 「别说了」 while Gemini's text is hidden | Her reply stops as today | unit |
| 6 | §15 re-ask after a blocked reply, local final present | The second text exactly; `heard=none` | unit |
| 7 | Source tree | No `OfflineSenseVoice`, `MultilingualModelStore` or 「多语言识别」; gates green | gate |
| 8 | App build | Builds on Codemagic | build |
| 9 | Device: install over build 53 (SenseVoice ready) | Next record has `asr-model removed bytes=` about 239,500,000; 设置 has no 多语言 row; the app's storage in iOS 设置 drops by about 240 MB | D |
| 10 | Device: 「现在几点」, 「What time is it」, 「今何時ですか」, 「Tudo bem, obrigado」 | First three shown in their language; the fourth shows 「（没听清）」 or a Chinese mishearing, never Portuguese; 「别说了」 still stops her at once | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-016n | Items 1–8; rows 1–10 | unit, gate, build, D |

**Trace gate.** Add `T-016n: F-05a` to `specs/trace-ids.txt` together with the first `@Test` that names T-016n.
