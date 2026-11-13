# F-07 Assistant voice (TTS) and playback

**Android status:** ACTIVE when an Azure voice is configured (ADR-016). iOS: Gemini 原声 by default (§15), 千问 (Qwen-Audio TTS) as the option (§14); Azure removed (§17, owner 2026-11-10).
**Depends on:** contracts/audio.md, §14 (Qwen-Audio TTS); contracts/api-contracts.md Azure section is Android only

## 1. Purpose
Speak judged reply text in one consistent Chinese voice with low latency, in clause order.

## 2. User-facing behaviour
She starts speaking quickly; the subtitle matches what she says; if TTS fails the subtitle still shows.

## 3. Preconditions
Azure key; reply passed the truthfulness gate.

## 4. Inputs and outputs
In: SpeechText clauses. Out: 24 kHz PCM to the player.

## 5. State transitions
Per reply: clauses queued → synthesising (≤2 in flight) → playing → done/cancelled.

## 6. Events and triggers
Interrupted, Error, Closed, VOIDED, cancelCurrentReply cancel the reply.

## 7. Dependencies and external services
Azure Speech REST.

## 8. Error handling and recovery
No fallback to Gemini audio on Azure failure; subtitle still shown.

## 9. Concurrency, cancellation, timeouts
Clause deadline 4000 + 400 ms × chars; warm-up every 15 s; playback epochs.

## 10. Acceptance criteria (iOS)
- Given a 3-clause reply, then clauses play in order with no gap >100 ms when warm (measure on device).
- Given barge-in during clause 2, then clause 3 never plays.
- Given Azure returns 401, then the subtitle shows and no Gemini audio plays.

## 11. Existing Android tests
`T/voice/AssistantVoiceRevoicerTest`, `AssistantVoiceRevoicerWaitCueTest`, `AzureSpeechVoiceTest`, `ClauseSegmenterTest`, `LowLatencyPlaybackBufferTest`, `PlaybackEpochEngineTest`, `WaitCuesTest`.

## 12. Source references (Android)
`A/voice/AssistantVoiceRevoicer.kt:26-55`; `A/voice/AzureSpeechVoice.kt:70,177,187-188`; `A/voice/PcmAudioPlayer.kt:121-136,631,684-767,820`; `A/voice/WaitCues.kt:33-39`.

## 13. Implementation constraints
Epoch-based flush is required for instant interruption.

## iOS notes (PROPOSED unless labelled)
`AVAudioPlayerNode` scheduling buffers; `AVSpeechSynthesizer` is NOT a substitute for parity (different voice) — PROPOSED.

## 14. Her voice from 阿里云百炼 Qwen-Audio TTS (owner request 2026-11-06)

**Why.** On 2026-11-06 several replies showed their text but made no sound. In the records (17:43 and 17:49 sessions), those turns have `reply` text and no `playback started`. In the phone log, requests timed out with `-1001` at 17:44:03, 17:44:25, 17:45:21 and 17:52:39. The 17:45:21 timeout ends the 12 s deadline of the 20-character reply 「抱歉，当前信息已过期，请重新说一下目的地。」 sent at 17:45:11. Azure's region on the phone is `japaneast`, and the phone's traffic goes through a VPN tunnel (`utun5`). The log hides host names, so this is matched by timing. Under §8, a failed clause silences the rest of the reply. `Revoicer`'s `onFailure` is not connected in `AgentRuntime`, so nothing records why. The owner judged Azure generally unreliable and asked for a replacement.

**Model choice.** The owner's 百炼 console (2026-11-06) shows these free quotas, valid until 2027-01-08:
- `qwen-audio-3.1-tts-flash`: 1M characters;
- `qwen-audio-3.1-tts-next`: 1M characters;
- `qwen3-tts-flash` and the 3.0 / 3.1-plus models: 10K each.

**`qwen-audio-3.1-tts-flash`** is used. It has the larger quota and documented Mandarin voices. It lets the client ask for raw PCM at 24 kHz. `qwen-audio-3.1-tts-next` appears only in the rate-limit table, with no API or voices documented, so it is not used.

**The owner's workspace is in Singapore.** The console's 「API Host」 is `ws-xhsnnriordxuw0ic.ap-southeast-1.maas.aliyuncs.com`, and the keys are `sk-ws-` workspace keys.

**Sources** (read 2026-11-06):
- [Qwen-Audio TTS HTTP API](https://help.aliyun.com/zh/model-studio/qwen-audio-tts-http-api):
  - endpoint, body fields, `format` (`mp3`/`pcm`/`wav`/`opus`) and `sample_rate` (24000 allowed);
  - `instruction`;
  - SSE with `X-DashScope-SSE: enable`, where `output.type` `sentence-synthesis` events carry base64 `output.audio.data`;
  - 3.1-flash is billed per token.
- [Voice list](https://help.aliyun.com/zh/model-studio/qwen-audio-tts-voice-list): voices must match the model, otherwise `InvalidParameter`.
- [User guide](https://help.aliyun.com/zh/model-studio/non-realtime-tts-user-guide): `instruction` examples; HTTP only.
- [Rate limits](https://help.aliyun.com/zh/model-studio/rate-limit): RPM 180.
- [Regions](https://help.aliyun.com/zh/model-studio/regions):
  - the host is `{WorkspaceId}.{region}.maas.aliyuncs.com`, shown as 「API Host」 in the console;
  - `dashscope.aliyuncs.com` gets no new features after 2026-09-30.

**Measured on a PC, 2026-11-06,** from Zhuhai through Clash, on the owner's Singapore host. These are scratch runs, not yet the item 1 script.
- **Key.** `dashscope.aliyuncs.com` rejects the `sk-ws-` key with 401 `InvalidApiKey`. The workspace host accepts it. So the host is required.
- **Voices.** On the Singapore host only the 龙安 voices work: `longanhuan_v3.1`, `longanlingxin_v3.1` and `longanfengyue_v3.1`. The 精品中文 voices (`baiqinglan_v3.1`, `yuxiaoyun_v3.1`, `anxiaolan_v3.1`, `yeqinghe_v3.1`, `longyan_v3.1`, `xieshurou_v3.1`, `loongbella_v3.1`) all fail with 400 `[cosyvoice:]Engine error [411]`.
- **Audio.** `pcm` comes back with no header, as 16-bit mono at 24 kHz: 176,640 bytes = 3.68 s for a 20-character sentence. One sentence arrives as 6–9 `sentence-synthesis` events, not one.
- **SSE parsing.** A `data:` line can arrive split across reads. A parser that reads line by line and parses each line on its own failed 2 of 8 runs with a JSON error. Events must be split on the blank line and their `data:` lines joined.
- **Speed, one kept-open connection, 10 runs** of 「你好，我是小诺。现在是下午五点四十九分。」 with `longanhuan_v3.1`, no `instruction`:
  - run 1, opening the connection: first audio 689 ms, all audio by 3,021 ms, worst wait between pieces 180 ms;
  - run 2: 886 ms, 1,974 ms, no wait;
  - runs 3–10: first audio 272–373 ms, all audio by 645–992 ms, no wait.
- **Speed, a new connection per request:** first audio 0.6–1.5 s, all audio by 1.5–7.7 s. Through Clash's HTTP proxy port the TLS handshake alone took 3,031 ms; without it, 258 ms.
- **`instruction`.** It is accepted, but it slows the start: with 「用温柔的语气说。」 first audio took 3.6–7.6 s, and all audio 5.4–12.7 s. Whether it changes the sound is not yet judged by ear.

**Not stated in the docs or measured yet:** the maximum characters per request (item 1 (c)), and the timing on the phone through its VPN (row 9).

1. **Check script, on a PC.** Add `scripts/tts_eval/qwen_tts_check.py`. It reads `DASHSCOPE_API_KEY` and `DASHSCOPE_API_HOST` from the environment only. It sends the item 3 request over one kept-open connection, writes a WAV to a scratch folder, and prints, for each run, chunk count, byte count, duration at 24 kHz 16-bit mono, time to first chunk, total time and the worst wait between pieces measured against playback. The runs are:
   - (a) the same short sentence 10 times on the workspace host;
   - (b) a 1,200-character text, to find the length limit;
   - (c) each voice in item 2 once.

   Record the results in `specs/STATUS.md` next to the measurements above.
2. **Choice in 设置.** The section 「Azure 区域和声音」 becomes 「她的声音」:
   - a picker **来源**: 「千问（阿里云）」 or 「Azure」;
   - for 千问, a required field **API Host**, with the text 「在百炼控制台的 API Key 页复制 API Host」. It accepts a bare host name only (no scheme, path or spaces); anything else shows 「API Host 格式不对」 and is not saved;
   - a picker **音色** with the three voices that work on the Singapore host, default `longanhuan_v3.1`:
     - 龙安欢 `longanhuan_v3.1`;
     - 龙安灵心 `longanlingxin_v3.1`;
     - 龙安风悦 `longanfengyue_v3.1`;
   - a **试听** button that speaks 「你好，我是小诺。」 in the chosen voice. A failure shows its code, for example 「试听失败：QWEN_TTS_VOICE」;
   - for Azure, the existing region and voice fields.

   New installs, and installs with a saved Qwen key and no saved choice, start on 千问. A saved choice is kept. A change applies from the next session start.
3. **Client `QwenSpeechClient: SpeechSynthesizer`** in `Packages/NovaServices/Sources/NovaServices/Qwen/`.
   - **Request.** `POST https://<host>/api/v1/services/audio/tts/SpeechSynthesizer` with headers `Authorization: Bearer <qwenAPIKey>`, `Content-Type: application/json` and `X-DashScope-SSE: enable`. The body is `{"model":"qwen-audio-3.1-tts-flash","input":{"text":<clause>,"voice":<voice>,"format":"pcm","sample_rate":24000}}`. No `instruction` is sent (item 4). The key is the existing Keychain `qwenAPIKey`, the same key `web_search` uses.
   - **One connection.** One `URLSession` per session, kept open, so requests after the first reuse the connection (measured: first audio about 0.3 s reused, against 0.7–1.5 s on a new connection).
   - **Response.** Events are split on the blank line, and each event's `data:` lines are joined before JSON parsing. For each `sentence-synthesis` event, the client decodes `output.audio.data` and appends it in order into one `PCMBuffer` at `PCMBuffer.replySampleRate` (24,000). The final event's `url` is not downloaded.
   - **Deadline.** The same §9 clause deadline (4,000 + 400 ms × characters) covers the whole request.
   - **Long clauses.** A clause over the limit is cut into pieces at the last `。！？；，` before the limit, or at the limit when there is none. The limit is the one item 1 (b) found, or 600 if none was found. The pieces are requested in order and their audio joined, so the queue still sees one clause.
   - **Codes** (I-8, codes only, never text):
     - `QWEN_TTS_TIMEOUT`, `QWEN_TTS_NETWORK`;
     - `QWEN_TTS_AUTH` (401, 403), `QWEN_TTS_RATE` (429);
     - `QWEN_TTS_VOICE` (an `InvalidParameter` code, or a 400 whose message holds `Engine error`);
     - `QWEN_TTS_HTTP_<status>` for other non-2xx statuses;
     - `QWEN_TTS_EMPTY` (no audio bytes);
     - `QWEN_TTS_BAD_STREAM` (an event that is not JSON, or has a non-empty error `code`).
   - **Warm-up.** `warmUp()` follows the Azure rule: one request of 「嗯」 at most every 15 s, never played. It also opens the kept connection before the first reply.
4. **Speaking style.** With 千问, no `instruction` is sent for any style, because it delayed first audio to 3.6–7.6 s. The style still sets the reply text as today. The table below is kept for a later task, once the owner has judged by ear whether `instruction` changes the sound:

   | Style | `instruction` |
   |---|---|
   | `default` | none |
   | `sweet` | 「用甜美的语气说。」 |
   | `gentle` | 「用温柔的语气说。」 |
   | `lively` | 「用活泼开朗的语气说。」 |
   | `tsundere` | 「用有点傲娇、不耐烦的语气说。」 |
5. **Session start.** A pure `VoiceSource.resolve(choice:qwenKey:qwenHost:azureKey:)` replaces the fixed Azure key check in `AgentRuntime`:
   - 千问 with a Qwen key and a host → Qwen;
   - 千问 missing either → 「请先在设置里保存千问 key 和 API Host」;
   - Azure → today's Azure check and region probe, unchanged.

   `SettingsReadiness.azureVoice` becomes `voice`, true when the chosen source is ready. The status row says 「她的声音」.
6. **One retry, both sources.** A clause that fails with a timeout, network or rate-limit code, or with a 5xx status, is requested once more with a fresh deadline before §8 applies. Auth, voice, empty and bad-stream codes are not retried. A barge-in or void during the retry cancels it as today (§6). The ordering in `RevoicerQueue` is unchanged: later clauses wait for this one.
7. **Failures are recorded.** `Revoicer`'s `onFailure` is connected. A failure that silences a reply writes `voice-failed turn=<n> source=<qwen|azure> code=<code>` to the record and to `RuntimeLog`, numbers and codes only.
8. **Timing line.** Every finished clause logs `voice source=<qwen|azure> chars=<n> first_ms=<n> ms=<n> attempt=<1|2>` to `RuntimeLog` and the record, so the 响应速度 sheet can compare sources.
9. **Network note.** The owner's TTS host is in Singapore. The README's device notes add that with a VPN or Clash on, `maas.aliyuncs.com` should be routed DIRECT (`DOMAIN-SUFFIX,maas.aliyuncs.com,DIRECT`), because Clash's TUN mode catches the name lookup even when no proxy is set.
10. **Not changed:**
    - Gemini audio is still dropped while revoicing;
    - the claim gate;
    - the clause segmenter, at most 2 in flight, in-order release and epochs;
    - no fallback voice: on a final failure the subtitle still shows (§8);
    - the Azure client, apart from the shared retry (item 6) and the failure line (item 7).

    The owner may ask for a fallback voice later.
11. **Where the code goes.**
    - `NovaServices/Qwen/`: the client, the SSE parsing, the text cutting and the voice list. The parsing and cutting are pure, so rows 2–5 run as unit tests.
    - `NovaCore`: the retry, as a small `SpeechSynthesizer` wrapper beside `Revoicer`, the host check, and `VoiceSource`.
    - `App/NovaDrive/SettingsView.swift` and `AgentRuntime.swift`: settings and wiring. The host goes in `UserDefaults`; it is not a secret.
    - Update `specs/ios-architecture.md` (the Revoicer row and the services table) and `specs/README.md` item 3 ("spoken by Azure TTS" → "spoken by a separate TTS: Qwen-Audio by default, Azure as an option").

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `qwen_tts_check.py` with a real key and host, runs (a)–(c) | Prints chunk count, bytes, duration, first-chunk, total and worst-wait ms per run; the length limit; which voices work; the result is in STATUS | script |
| 2 | Build the request for 「现在是下午五点。」, voice `longanhuan_v3.1`, style `gentle` | URL with the host, the three headers, and the body exactly as item 3, with no `instruction` | unit |
| 3 | An SSE body: `sentence-begin`, 3 `sentence-synthesis` events (one with its `data:` line split across two reads), `sentence-end`, then the final event with `url` | One 24 kHz buffer, the 3 decoded parts joined in order; the URL is not fetched | unit |
| 4 | Status 401; 429; 500; 400 with `InvalidParameter`; 400 with `Engine error [411]`; 200 with no audio; an event with an error `code`; the deadline passes | `QWEN_TTS_AUTH`, `QWEN_TTS_RATE`, `QWEN_TTS_HTTP_500`, `QWEN_TTS_VOICE`, `QWEN_TTS_VOICE`, `QWEN_TTS_EMPTY`, `QWEN_TTS_BAD_STREAM`, `QWEN_TTS_TIMEOUT` | unit |
| 5 | A clause of 2.2 × the limit | Three requests, each within the limit, cut at punctuation; the audio is joined in order | unit |
| 6 | First attempt times out, the second succeeds; both fail; first gives `QWEN_TTS_AUTH` | Played once with `attempt=2`; one `voice-failed` line and the subtitle only; no retry | unit |
| 7 | `VoiceSource.resolve`: 千问 with key and host; 千问 with key and no host; 千问 with no key; Azure; new install with a Qwen key. Host check: `ws-x.ap-southeast-1.maas.aliyuncs.com`; `https://ws-x.ap-southeast-1.maas.aliyuncs.com/`; `a b` | Qwen; the 千问 message; the 千问 message; the Azure path; 千问 chosen. Accepted; rejected; rejected | unit |
| 8 | Record lines for a failure and a finished clause | `voice-failed turn=… source=… code=…` and `voice source=… chars=… first_ms=… ms=… attempt=…`, with no reply text | unit |
| 9 | Device, 千问, VPN on with `maas.aliyuncs.com` DIRECT: 20 replies, some long | Every reply with text has `playback started`; no `voice-failed`; `first_ms` after the first reply mostly under 1,000; note it in the 响应速度 sheet | D |
| 10 | Device: 试听 each of the 3 voices; choose one; start a session | Each speaks; the session uses the chosen voice | D |
| 11 | Device: switch to Azure, start a session | The Azure voice, with today's region check | D |

**Trace gate.** Add `T-020a: F-07` to `specs/trace-ids.txt` together with the first `@Test` that names T-020a.

## 15. Her voice is Gemini Live's own voice by default (owner decision 2026-11-07)

**Why.** Device 2026-11-07, 1f05a54, session 11:46:56. The owner says the Qwen voice is obviously not the Gemini voice, and wants the fastest option with the current Gemini voice. In the weather turn of that session, `query_live_info` returned at +8,041 ms, Gemini's reply began at +8,913, Gemini finished at +9,755, and Qwen's first sound played at +11,494. A separate TTS can start only after Gemini's text exists, plus its own request. Gemini Live already sends her audio, in the live session's voice `Leda` (`RealtimeConfig.voiceName`), with the reply.

**Already built, reused as is.** Without revoicing (`Settings.revoicing == false`), Gemini's reply audio goes through `DriverTurnPipeline` as `speechAudio`, so the claim gate holds audio and subtitle together (I-1, I-5; `specs/ios-architecture.md` §5.2). The existing rules stay as they are:
- a proven claim releases its audio at once, except while navigation or music evidence is outstanding;
- a clean chat turn releases its text as it comes and its audio at `generationComplete`;
- a disproven claim voids the turn before it is heard.
One rule changes, by owner decision (2026-11-07, see the next paragraph): a clean chat turn no longer waits for `generationComplete`.

1. **Choice in 设置.** 「她的声音」 来源 becomes: **「Gemini 原声（最快）」** (first and default), 「千问（阿里云）」, 「Azure」. Gemini 原声 has no fields and needs no extra key. 试听 is hidden for it, because its voice only exists inside a session.
2. **Which installs move.** New installs, and installs whose saved choice is 千问 from 1f05a54, start on Gemini 原声. This move happens once, on first launch of this build, and is remembered. Any choice saved after that is kept.
3. **Session start.** `VoiceSource.resolve` gains `.gemini`. It is always ready, because the session cannot start without the Gemini key. With `.gemini`, `Settings.revoicing` is false. No `Revoicer`, no TTS warm-up and no Qwen or Azure connection is created for the session.
4. **Clearer missing message.** 「请先在设置里保存千问 key 和 API Host」 is replaced by a message naming only what is missing: 「请先在设置里保存千问 key」 or 「请先在设置里保存千问 API Host」.
5. **Timing line.** For each turn whose audio is played, `RuntimeLog` and the record get `voice source=gemini turn=<n> held_ms=<first audio received → first audio played> first_ms=<utterance sent → first audio played>`, so the 响应速度 sheet can compare sources and show the hold.
6. **Not changed:** the claim gate and its hold rules; barge-in and epochs; the Qwen and Azure clients and §14, kept as options; F-24 reconnection.

**Stream, and cut on a bad claim (owner decision 2026-11-07).** The owner asked why her audio is collected instead of streamed. Copied from the OpenAI Agents SDK realtime agents: audio plays as it arrives, output guardrails run on the transcript as it grows (every 100 characters by default, `debounceTextLength`), and a tripped guardrail interrupts the response ([guardrail source](https://cdn.jsdelivr.net/npm/@openai/agents-realtime@0.11.6/dist/guardrail.d.ts), [Python SDK issue 1912](https://github.com/openai/openai-agents-python/issues/1912)). Here the guardrail is the existing claim check, run on every `replyText` as today (no debounce: it is local and cheap).

7. **Clean chat turns stream.** With Gemini 原声, `DriverTurnPipeline`'s clean verdict releases audio as it comes, the same as text, instead of at `generationComplete`. The proven and pending rules are unchanged: a turn with a claim still holds its audio until the `ok=true` result.
8. **A bad claim cuts what is playing.** When a claim appears in the transcript of a turn whose audio is already playing and it is disproven, the turn is voided as today: playback flushes to a new epoch at once, the subtitle is removed, and the correction nudge is sent. The record gets `claim-cut turn=<n> played_ms=<audio already heard>`.
9. **I-5 changes.** `specs/product-spec.md` I-5 gains: 「With Gemini 原声, a clean turn's audio streams; a false claim found in its transcript cuts it at once (owner 2026-11-07).」 Qwen and Azure keep the held behaviour.


| # | Given / when | Then | Test |
|---|---|---|---|
| 12 | No saved choice; saved 千问 on first launch of this build; saved 千问 after that launch; saved Azure; 千问 with a key but no host | Gemini 原声; Gemini 原声; 千问; Azure; 「请先在设置里保存千问 API Host」 | unit |
| 13 | Source Gemini 原声: a clean chat turn; a proven `control_climate` turn; a disproven claim before any audio played; a claim in the transcript after 800 ms of audio played, then disproven | `revoicing` false, no `Revoicer` made; each audio part released as it arrives, `held_ms` 0; audio at the `ok=true` result; nothing heard, turn voided; playback flushed at once, `claim-cut turn=<n> played_ms=800`, nudge sent | unit |
| 14 | Device: 设置 shows Gemini 原声 selected; 10 everyday replies, including 「现在天气怎么样」 and 「打开空调」 | Her voice is the live session's voice; every reply has `playback started`; `first_ms` and `held_ms` noted in the 响应速度 sheet against the Qwen rows of 1f05a54 | D |
| 15 | Device: 「打开空调」; 「有蚊子」 then 「那怎么办？」; 20 chat replies | 「空调开了」 is heard only after the air-con changes; no claim of an action that did not happen; count any `claim-cut` lines | D |
| 16 | Device: switch to 千问, then Azure; a session each | Each still speaks as before | D |

## 16. Her Gemini voice sounds like an old woman on the phone (owner report 2026-11-07, find out first)

**Why.** Owner 2026-11-07, eef9860: 「the original gemini voice is good」 but in the app she sounds like an old woman. The records of sessions 14:42:01, 14:42:07 and 17:10:57 show only `voice source=gemini`, so it is Gemini's own audio (`Leda`, 24 kHz) as our app plays it, not Qwen or Azure. Playback runs in an `AVAudioSession` with `.playAndRecord`, mode `.voiceChat` and voice processing on (`LiveAudio.swift`, F-04a §4 layer 1). Cause not known; nothing is changed until it is.

1. **Keep what was received.** A 设置 → 开发 switch 「保存她的原声」 (off by default). When on, each turn's reply audio is written exactly as received from Gemini (24 kHz, 16-bit mono, before any playback processing) to `Documents/conversations/<record>-turn<n>.wav`.
2. **Log the playback format.** At session start: `playback format rate=<Hz> channels=<n> mode=<session mode> voiceProcessing=<on|off>`.
3. **Not changed:** voice, echo cancellation, session mode, playback path.

| # | Given / when | Then | Test |
|---|---|---|---|
| 17 | Switch on, a 2-turn reply fixture | Two WAV files, 24 kHz mono 16-bit, bytes equal to the received audio; switch off: none | unit |
| 18 | Device: switch on, 5 replies | The WAV files pulled to the PC; the owner compares them with the phone's sound and with Leda in AI Studio; `playback format` line noted | D |

## 17. Azure removed from the iOS app (owner decision 2026-11-10, APPROVED)

**Why.** Owner 2026-11-10: remove Azure completely. The owner had already judged Azure unreliable (2026-11-06: japaneast requests timed out through the VPN, T-020a), and Gemini 原声 has been the default since T-020b. T-090 kept Azure only because it was still selectable in 设置 (F-25 §14). After this change her voice comes from 「Gemini 原声（最快）」 (the default) or 「千问（阿里云）」.

1. **Delete the client.** Delete `Packages/NovaServices/Sources/NovaServices/Azure/` (`AzureSpeechClient`, `AzureSpeechConfig`, the SSML builder and the `express-as` style table) and `AzureSpeechTests`. In `App/NovaDrive/AgentRuntime.swift`, delete `AzureRegionProbe` and the `.azure` branch of the session-start voice choice, with its notices 「请先在设置里保存 Azure Speech key」, 「正在识别 Azure 区域…」 and 「Azure key 在常用区域都无效，请在设置里填写区域」.
2. **Settings.** 她的声音 来源 lists Gemini 原声 and 千问 only. The Azure 区域 and 声音 fields go, and the 「Azure Speech key」 row leaves the keys list. Removed: `VoiceSourceKind.azure`, `VoiceSourceDecision.azure`, `CredentialKey.azureSpeechKey`, `SettingsKey.azureVoice`, `DriveSettings.azureRegion`, `DriveSettings.azureVoice`, `DriveSettings.defaultVoice`, the default-voice seeding in `SettingsView` and the Azure branch of `SettingsReadiness`. `VoiceSource.migrated` (§15 item 2) loses its Azure case. A saved source that no longer parses reads as Gemini 原声, as `effectiveChoice` already does.
3. **Installed phones, once.** On the first launch of this build, once, remembered under `azure_removed_done`:
   - a saved source `azure` becomes Gemini 原声;
   - the Keychain item `azure_speech_key` is deleted, so no unused secret stays on the phone;
   - UserDefaults `azure_region` and `azure_voice` are removed.

   Nothing is logged about the key (I-8). A failed Keychain delete does not block launch and is tried again on the next launch: the flag is set only after the delete succeeds or finds no item.
4. **Shared voice parts renamed, not changed.** `AzureSpeechTuning` is also used by `RevoicerQueue`, the 千问 path and 试听. It becomes `SpeechTuning` with the same values: connect 5 s, clause deadline 4000 ms + 400 ms per character, warm-up every 15 s, 2 requests in flight. `RetryingSpeechSynthesizer` drops the `AZURE_TTS_*` codes; the `QWEN_TTS_*` codes and the one-retry rule are unchanged. Comments that name Azure (`Revoicer`, `RevoicerQueue`, `AgentState`, NovaPorts `Audio.swift`) say 「TTS」 or 「千问」 instead.
5. **Speaking style goes to the prompt only.** Azure `express-as` was the only place the style reached synthesis; 千问 sends no style (§14: an instruction delays first audio). `SpeechSynthesizer.synthesize` and `synthesizeTimed` lose their `style:` parameter, and `Revoicer` loses its `style` closure. `SpeakingStyle` stays: 「说话嗲一点」 and the other styles change her wording through the system instruction, for every source (F-21, unchanged).
6. **Guard.** A gate test fails if `azure` (any case) appears in a file under `App/` or `Packages/`, in its text or its path. Build note (T-020d): the item 3 cleanup must name the retired keys, so `RetiredVoiceSettings.swift` and its test `RetiredVoiceSettingsTests.swift` are the only files the gate (`check_imports.py`) allows to name them. The secrets-gate fixtures in `scripts/gates/tests/test_gates.py` keep `AZURE_SPEECH_KEY` and `azure_speech_key` as sample key names, because they test that the secrets scanner catches such names; they are not app code.
7. **Specs.** Text describing current iOS behaviour stops naming Azure as an option:
   - the F-07 title and status lines here, and the F-07 row in `features/README.md`;
   - F-22 `settings-credentials.md` (the secrets and non-secrets lists, §7 and §11);
   - F-21 `persona-style.md` §7;
   - F-20a `camera-view.md` (the voice line);
   - `mandarin-transcript.md` (the fixed-label list);
   - `contracts/api-contracts.md` (the Azure section is marked 「Android only; removed from iOS, F-07 §17」) and `contracts/audio.md` (the reply-audio row);
   - `ios-architecture.md` (the NovaServices list, the `SpeechSynthesizer` port, Revoicer, reply lane, Keychain, TTS failure, F-07 mapping and M1 rows).

   History stays as written: `STATUS.md`, `progress/`, `work.json` notes, ADR-016 (the Android decision), and §14–§15 here, which describe Azure as the option it was then. §15 row 12's case 「saved Azure → Azure」 now expects Gemini 原声 (row 20).
8. **Not changed:** Gemini 原声, its streaming and the claim cut (§15); 千问 and 试听 (§14); the revoicer queue, epochs and barge-in; F-21 styles and their confirmations; the T-032d preview path.

| # | Given / when | Then | Test |
|---|---|---|---|
| 19 | Source tree after the change | No `azure` (any case) in `App/` or `Packages/` (gate test); `scripts/gates/run_all.sh` green | unit (gate) |
| 20 | Voice choice: saved `azure` on the first launch of this build; saved `qwen` with key and host; nothing saved; §15 migration with saved `azure` | Gemini 原声; 千问; Gemini 原声; Gemini 原声 | unit |
| 21 | First launch with `azure_speech_key` in the store and `azure_region`, `azure_voice` saved; a second launch; a first launch whose Keychain delete fails | Key deleted, both values removed, `azure_removed_done` set; the second launch changes nothing; flag not set, the delete is tried again on the next launch | unit |
| 22 | 千问 revoices a 3-clause reply using `SpeechTuning` | Same deadlines as before (10 characters → 8000 ms), at most 2 in flight, played in order; `QWEN_TTS_RATE` retried once | unit |
| 23 | App build | Builds; 她的声音 来源 has two options | build |
| 24 | Device: a phone with Azure saved as the source and an Azure key stored; install this build | 设置 → 她的声音 shows Gemini 原声 selected and only two options, with no Azure key row; a session speaks in the Gemini voice; 「说话嗲一点」 changes her wording and she still does what is asked | D |
| 25 | Device: switch to 千问; one session | She speaks as before (§14) | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-020d | Items 1–8; rows 19–25 | unit, build, D |
