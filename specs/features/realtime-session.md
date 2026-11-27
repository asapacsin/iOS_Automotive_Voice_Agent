# F-05 Realtime session (Gemini Live)

**Android status:** ACTIVE provider. Qwen frozen, Baidu dormant.
**Depends on:** contracts/voice-agent.md, contracts/api-contracts.md (Gemini)

## 1. Purpose
Hold one realtime conversation with Gemini Live: stream audio up, receive transcripts, tool calls and reply.

## 2. User-facing behaviour
Natural back-and-forth; reconnects silently after a network blip.

## 3. Preconditions
Gemini API key, consent accepted, network.

## 4. Inputs and outputs
- Transport: WebSocket `BidiGenerateContent` (v1beta), header `x-goog-api-key`; connect timeout 10 s,
  ping every 10 s with a 5 s pong wait (any frame received counts as alive), `setupComplete` within 10 s.
- Setup: `responseModalities=[AUDIO]`, `languageCode=zh-CN`, prebuilt voice (default Aoede; owner 2026-11-10, Leda sounded awkward in Mandarin; Aoede (owner choice after listening; recommended with Kore and Charon) per [Towards AI test of all 30 voices](https://pub.towardsai.net/i-tested-all-30-voices-in-googles-new-gemini-3-1-af7ae23e4202)),
  `systemInstruction` (persona + style, F-21), `tools.functionDeclarations` (`parametersJsonSchema`),
  automatic activity detection (start LOW, end HIGH), input/output transcription, sliding-window context
  compression, `sessionResumption{handle}`. **iOS: no `thinkingLevel`** — the live model closes 1007
  MALFORMED when it is present (device finding 2026-10-26, commit e7ab046).
- Client → server: `realtimeInput.audio` (16 kHz PCM, base64), `audioStreamEnd`, `clientContent`,
  `toolResponse.functionResponses`.
- Server → client: `setupComplete`, `goAway`, `sessionResumptionUpdate`, `serverContent` (transcriptions,
  model audio, `interrupted`, `generationComplete`, `turnComplete`), `toolCall`, `toolCallCancellation`.
- Close codes: 1007 on a resumed setup → clear the handle, `RESUME_UNAVAILABLE` (retryable); 1007 on a
  fresh setup → terminal (MALFORMED); 1008 not about auth/quota → `CONNECTION_CLOSED` (retryable).

## 5. State transitions
contracts/voice-agent.md §1 and §4.

## 6. Events and triggers
setupComplete, serverContent, toolCall, toolCallCancellation, goAway, sessionResumptionUpdate, interrupted.

## 7. Dependencies and external services
Gemini Live API.

## 8. Error handling and recovery
contracts/voice-agent.md §8; resumption handle kept in memory, cleared on disconnect; 1007/1008 handling.

## 9. Concurrency, cancellation, timeouts
Events serialised; WebSocket reader thread owns turn state; event buffer 1024.

## 10. Acceptance criteria (iOS)
- Contract tests replay recorded Gemini server messages and assert the emitted event order of §4.
- Given a socket drop mid-turn, when reconnecting with a handle, then the conversation continues and the UI shows PROCESSING, not ERROR.
- Given an auth error, then no retry and a config message is shown.

## 11. Existing Android tests
`T/voice/GeminiLiveClientTest`, `GeminiLiveProtocolTest`, `GeminiLiveProviderVoiceTest`, `GeminiTurnTimingTest`, `GeminiTurnDiagnosticsTest`, `RealtimeProviderFactoryTest`, `VoiceSessionControllerTest`, `VoiceSessionStateMachineTest`, `RealtimeProviderContractTest`.

## 12. Source references (Android)
`A/voice/GeminiLiveClient.kt:46,59,128,170,454-502,607-632`; `GeminiLiveProtocol.kt:40-83,188-251,313-342`; `I/VoiceSessionController.kt:356,385-475,586-608`; `I/ReconnectPolicy.kt`; `A/GeminiSettings.kt` (`QWEN_FROZEN`).

## 13. Implementation constraints
Keep the provider-neutral contract (I-13); the iOS app must not depend on Gemini types outside the adapter.

## iOS notes (PROPOSED unless labelled)
`URLSessionWebSocketTask` (PROPOSED); verify ping/keepalive and 10 s setup timeout. Background socket lifetime limited by iOS (see ios-feasibility).

## 14. Callbacks answered once: no crash when the network drops (iOS, APPROVED 2026-10-30)

**Why.** Device run 16a3c13 (2026-10-30 17:37): turning on airplane mode mid-conversation closed the app. Crash
report `NovaDrive-2026-10-30-173715.ips`: `EXC_BREAKPOINT` on thread `com.apple.NSURLSession-delegate`, frames
`URLSessionWebSocketConnection.ping()` closure → `CheckedContinuation.resume(throwing:)` → `_assertionFailure`. Cause:
`ping()` (Packages/NovaRealtime/Sources/NovaRealtime/Transport/WebSocketTransport.swift) resumes a checked
continuation inside `URLSessionWebSocketTask.sendPing`'s handler; when the socket dies, URLSession can call that handler
more than once (failure, then cancellation), and a second `resume` on a checked continuation is a deliberate crash. The
same risk exists wherever a continuation wraps an Apple callback that is not guaranteed to fire exactly once. A tunnel,
car park or weak signal breaks the socket the same way, so this can crash on a real drive. Owner 2026-10-30: "write this
is spec".

**Rule in plain words.** When iPhone answers a waiting request, the app takes the first answer and quietly ignores any
repeat. A duplicate answer is never a crash. What the app does with the first answer does not change.

1. **One-shot helper.** Add `ResumeOnce<T>` (a lock plus a done flag) in the lowest package the call sites already
   import (pure Swift, no UIKit/AVFoundation; NovaCore/NovaKit if reachable, else NovaRealtime and NovaPlatform each
   keep their own copy). `resume(returning:)`, `resume(throwing:)`, `resume(with: Error?)`: the first call resumes the
   continuation and returns `true`; every later call does nothing and returns `false`. Thread-safe from any queue.
2. **Ping.** `URLSessionWebSocketConnection.ping()` uses `ResumeOnce`. The first result decides (success, or the error
   that F-24 already turns into reconnecting); later calls are dropped. A dropped duplicate is logged once per socket as
   `duplicateCallback site=ping` (no payload).
3. **Audit the other wrappers.** Every `withCheckedContinuation` / `withCheckedThrowingContinuation` outside Tests is
   classified in the PR description as either (a) wraps an Apple or vendor callback, delegate or completion handler, or
   (b) resumed only by app code that already guarantees one resume. All (a) sites switch to `ResumeOnce` with their own
   `site=` name. Known (a) candidates: `CameraSession.swift` (3 sites), `SystemSpeechGuidanceVoice.swift`. (b) sites stay
   as they are; if one cannot be shown to resume exactly once, it is treated as (a).
4. **Never left waiting.** `ResumeOnce` fixes a second answer, not a missing one. A site whose callback may never come
   keeps (or gets) its existing timeout or cancellation path; the ping keeps F-24's ping timeout. No site may change from
   crash to hang.
5. **Behaviour after a drop is unchanged.** After the first ping failure the session follows F-24 (reconnecting, retry
   with the resumption handle when the network returns). This section only removes the crash that prevented it.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `ResumeOnce` resumed twice (success then error, error then error, from two threads at once) | First value delivered once; second call returns `false`; no crash | unit |
| 2 | Fake `sendPing` that calls its handler twice (error, then cancel error) | `ping()` throws once; no crash; one `duplicateCallback site=ping` log | unit |
| 3 | Fake `sendPing` that calls back once | Same result as today (success or error) | unit |
| 4 | Every (a) site from item 3 | Uses `ResumeOnce`; a test per site calls its callback twice without crashing, where the callback can be faked | unit + review |
| 5 | `check`: no new raw `CheckedContinuation.resume` in a closure handed to an Apple or vendor API | Reviewer confirms in the audit list | review |
| 6 | Device: mid-conversation, turn on airplane mode, wait 20 s | App stays open; shows reconnecting, not closed; no new NovaDrive `.ips` crash report | D |
| 7 | Device: then turn airplane mode off | Reconnecting by itself is F-24 §14 (T-016h), not this task; here only: still no crash | D |
| 8 | Device: walk into a lift or underground car park mid-conversation, then out | No crash (reconnect: F-24 §14 row 9) | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-016g | §14 items 1–5: `ResumeOnce` helper, ping fix, audit and switch of Apple-callback continuation sites, duplicate log; unit tests rows 1–4; device rows 6–8 | unit, review, D (rows 6–8) |

## 15. Choosing the voice model: Gemini Live or Qwen-Audio Realtime (iOS, owner request 2026-11-26)

**Why (owner, 2026-11-26).** The voice model is reached over the VPN. PC measurements on 2026-11-26, from this PC
through the owner's VPN: exit Los Angeles, a Gemini request about 1.3 s, a Live session ready about 1.6 s; exit
Amsterdam, about 2.3 s and 1.6 s; 3 connections dropped mid-handshake. The owner's 百炼 (Beijing) account has
`qwen-audio-3.1-realtime-flash` (1M free tokens until 2027-01-26) and `qwen-audio-3.1-realtime-plus` (1M until
2026-12-18), which run in Beijing with no VPN. The owner wants to switch between them and Gemini in the app and compare.

**What the app has.** App logic sees the voice model only through `RealtimeProvider` (NovaPorts `Realtime.swift`, I-13):
`connect`, `sendAudio`, `sendAudioStreamEnd`, `sendToolResponses`, `sendText`, `close`, and the provider-neutral
`RealtimeEvent`s. `GeminiLiveProvider` (NovaRealtime) is the only implementation.

**Vendor facts this copies (Alibaba Model Studio, read 2026-11-26).** [Qwen-Audio realtime user guide](https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-user-guides),
[WebSocket API](https://help.aliyun.com/en/model-studio/qwen-audio-realtime-websocket-api),
[client events](https://help.aliyun.com/zh/model-studio/fun-audiochat-client-events),
[server events](https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-server-events):
- WebSocket `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=<model>` (Beijing public endpoint, fixed in the
  app like the other 百炼 calls in `QwenRoute`), header `Authorization: Bearer <key>`. Changed 2026-11-26 (T-016r):
  the first build used the workspace host `wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/...` taken from the saved
  千问 voice API Host; on the phone that host was a Singapore workspace (`…ap-southeast-1.maas.aliyuncs.com`) and the
  Beijing key got `session failed code=AUTH` (record 20261126-174516, build 55f99fb). PC handshake 2026-11-26 with the
  Beijing key and `qwen-audio-3.1-realtime-flash`: `dashscope.aliyuncs.com` 101 (accepted); `ws1.cn-beijing.maas…`
  400 「Workspace endpoint is invalid」; `{WorkspaceId}.cn-beijing.maas…` 403; the Singapore host 401. Input PCM 16 kHz mono 16-bit (as the app sends Gemini), output PCM 24 kHz (as Gemini).
- `session.update` with `instructions`, `voice` (first update only; 3.1 default `longanqian_v3.1`), `turn_detection`
  (`server_vad`, `smart_turn`, `smart_turn_v2` recommended, or `null`), `tools` (OpenAI function shape; first update
  only), `max_history_turns` (1–50), `modalities`.
- Tool calls arrive as `response.function_call_arguments.done` (`call_id`, `name`, `arguments`); the result goes back
  as `conversation.item.create` with `{"type":"function_call_output","call_id","output"}`, then `response.create`.
- Limits: 50 audio turns and 300 seconds of audio kept as context; older history dropped. No session resumption, no
  `goAway`, no tool-call cancellation, no asynchronous (non-blocking) tool scheduling.

1. **Setting.** 设置 gains 「语音模型」 with three choices: `Gemini 3.8 Live` (default, today's), `Qwen Audio 3.1 Flash`
   (`qwen-audio-3.1-realtime-flash`), `Qwen Audio 3.1 Plus` (`qwen-audio-3.1-realtime-plus`). Stored on the phone; it
   takes effect at the next connect (a running session is not switched; the row says 「下次连接时生效」). A Qwen choice
   needs the 百炼 key already saved for search (F-18 §40); without it the choice is shown disabled with
   「先在设置里填百炼 key」. The saved 千问 voice API Host (F-07 §14) is not used and not required for the voice model.
2. **One provider per choice.** `AgentRuntime` builds `GeminiLiveProvider` or the new `QwenRealtimeProvider`
   (NovaRealtime) from the setting. Nothing above `RealtimeProvider` changes: the same instruction text, the same 25
   tools (`AgentSetup`), the same tool dispatch, record and UI.
3. **`QwenRealtimeProvider` sends.**
   - `connect`: opens the socket above; the first `session.update` carries `instructions` (the app's instruction as
     sent to Gemini), `tools` (each declared tool converted to `{"type":"function","function":{name, description,
     parameters}}`, the same schema), `turn_detection` `{"type":"smart_turn_v2"}`, `max_history_turns` 50, the default
     voice, `modalities` `["text","audio"]`. `setupComplete` is emitted on `session.updated`.
   - `sendAudio`: `input_audio_buffer.append` with base64 PCM, in the frames the capture already makes (20–40 ms).
   - `sendToolResponses`: per response, `conversation.item.create` `function_call_output` with the result JSON as
     `output`; one `response.create` after the last one of a batch.
   - `sendText`: each turn as `conversation.item.create` `message` (role user, `input_text`); `response.create` when
     `turnComplete`.
   - `close`: closes the socket.
4. **`QwenRealtimeProvider` maps events** to `RealtimeEvent`:
   `conversation.item.input_audio_transcription.delta/.completed` → `userTranscript(…, isFinal:)`;
   `response.created` → `responseStarted`; `response.audio_transcript.delta` → `replyText`; `response.audio.delta` →
   `replyAudio`; all `response.function_call_arguments.done` of one response → one `toolCalls`; `response.audio.done` →
   `audioDone`; `input_audio_buffer.speech_started` while a response is open, or `response.done` with `status=cancelled`
   and `reason=turn_detected` → `interrupted(.serverVAD)`; `response.done` → `responseDone(completed|cancelled)`;
   `error` with `type=server_error` or a socket failure → `failed` with the matching `RealtimeErrorCode` (401/403 →
   `auth`, quota or `Arrearage` → `quota`, 429 → `rateLimited`, else `connectionClosed`); socket end → `closed`.
   Never emitted: `resumptionHandle`, `goAway`, `toolCallCancellation`.
5. **What Qwen lacks, handled by code.**
   - **No resume.** A dropped Qwen session reconnects fresh (F-24 recovery as for a Gemini session without a handle);
     the conversation summary note (as after an app restart) is sent as the first text turn. Record `qwen reconnect
     fresh=yes`.
   - **No background tools.** Tools that run in the background on Gemini (`NON_BLOCKING`, result `WHEN_IDLE`:
     `find_events`, `plan_trip`, `web_search` and the others marked so) answer at once with the existing handoff result
     (「好，我去查…，好了告诉你」); their final result is sent later as a text turn, the path F-18 §37 item 3 already uses
     after a reconnect. Blocking tools are unchanged.
   - **Short memory.** 300 s of audio and 50 turns. The app sends nothing extra for it; the record logs
     `qwen history turns=<n>` each turn so the limit shows in tests.
6. **Record.** The header gains `voiceModel <gemini-3.8-live|qwen-audio-3.1-realtime-flash|…>`; Qwen sessions log
   `qwen usage in=<audio>,<text> out=<audio>,<text>` from each `response.done` (tokens; numbers only, I-8).
7. **Not changed.** Gemini stays the default and its provider is untouched. Speaker lock, echo handling, barge-in,
   playback, tools, search, trips and their texts are the same for both.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 9 | **PC, before the build:** `qwen-audio-3.1-realtime-flash` with the app's instruction and 25 tools (from `AgentSetup`); text turns 「导航去珠海站」, 「这周末珠海澳门有什么展览」, 「大三巴牌坊有什么历史」 | Connects; `navigate_to` and `find_events` called with right arguments; a tool result answered in speech; time to first audio and tokens per turn recorded in STATUS. Not met: stop and report, no build | PC |
| 10 | Setting 「语音模型」 | Three choices; Gemini default; Qwen choices disabled without the 百炼 key; change shows 「下次连接时生效」 | unit |
| 11 | `QwenRealtimeProvider.connect` (fake socket) | First message is `session.update` with instructions, the tools converted, `smart_turn_v2`, `max_history_turns` 50; `setupComplete` on `session.updated` | unit |
| 12 | Fake server events (transcript, audio, two function calls, `response.done` completed and cancelled, `error`) | The `RealtimeEvent`s of item 4, in order; two calls in one `toolCalls` | unit |
| 13 | `sendToolResponses` with two results | Two `function_call_output` items, one `response.create` | unit |
| 14 | `plan_trip` on Qwen | Handoff result at once; final result later as a text turn | unit |
| 15 | Socket drops on Qwen | Fresh reconnect with the summary note; `qwen reconnect fresh=yes` | unit |
| 16 | Device: Qwen Flash, VPN off: 「导航去珠海站」, 「有点困了」, 「这周末珠海澳门有什么展览」 | Navigation starts; rest stop found; events answered later; first sound times in the record compared with a Gemini run | D |

**Trace gate.** Add `T-016q: F-05` to `specs/trace-ids.txt` with the first `@Test` that names T-016q.

| Task | Scope | Status |
|---|---|---|
| T-016q | §15 items 1–7; rows 9–16 (row 9 before the build) | NOT_RUN |
