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
  ping 20 s, `setupComplete` within 10 s.
- Setup: `responseModalities=[AUDIO]`, `languageCode=zh-CN`, prebuilt voice (default Leda),
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
