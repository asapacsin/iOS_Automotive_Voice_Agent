# F-24 Network recovery

**Android status:** IMPLEMENTED (JVM; fault injection `NetworkFaults.dropConnectionNow`).
**Depends on:** contracts/voice-agent.md §8

## 1. Purpose
Survive brief network loss without losing the conversation.

## 2. User-facing behaviour
UI shows PROCESSING while reconnecting; conversation resumes with context.

## 3. Preconditions
A session that reached LISTENING at least once (with a resumption handle when the server gave one).

## 4. Inputs and outputs
- In: socket close / error with a code.
- Out: UI state RECONNECTING (chip PROCESSING, amber) then LISTENING, or ERROR with the code on the chip.

## 5. State transitions
LISTENING/THINKING/SPEAKING → RECONNECTING → LISTENING (resumed with the handle), or → ERROR after 5 failed
attempts. Terminal errors go straight to ERROR (contracts/voice-agent.md §8).

## 6. Events and triggers
WebSocket close/failure, setup timeout, server goAway; optional `NWPathMonitor` path change (PROPOSED).

## 7. Dependencies and external services
Gemini Live WebSocket (F-05).

## 8. Error handling and recovery
- Retryable: DISCONNECT, CONNECTION, DNS, TIMEOUT, WS_FAILED, TLS_FAILED, UNAVAILABLE, RESUME_UNAVAILABLE.
- Terminal: auth, credential, quota/rate, malformed/invalid model (e.g. close 1007 MALFORMED).
- Reply audio of the dropped turn is flushed (epoch); a tool already executed is not repeated.
- RESUME_UNAVAILABLE → a new session without the handle; she does not claim to remember the lost turn.

## 9. Concurrency, cancellation, timeouts
5 attempts, 200 ms initial, doubling, 8 s cap. A second error from the same dying socket joins the
reconnect in flight. Setup must complete within 10 s per attempt.

## 10. Acceptance criteria (iOS)
- Given a forced socket drop, reconnect within the policy and resume with the handle (integration test against a fake server).
- No app-level connectivity monitor exists on Android (UNVERIFIED); iOS may add `NWPathMonitor` as an improvement, not parity.

## 11. Existing Android tests
`T/voice/WorkReconnectDiagnosticsTest`, `VoiceSessionControllerTest`.

## 12. Source references (Android)
`I/ReconnectPolicy.kt:12`; `I/VoiceSessionController.kt:586-608`; `A/voice/NetworkFaults.kt:13`; `GeminiLiveProtocol.kt:313-324`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
`NWPathMonitor` optional (PROPOSED).

## 14. Wait for the network instead of failing (iOS, APPROVED 2026-10-30)

**Why.** Device run 16a3c13 (2026-10-30 17:39): after airplane mode the app showed 连接失败 and stayed there after the
network came back. Cause: §5/§9 spend all 5 attempts (200 ms doubling, 8 s cap, about 6–15 s in total) even when there
is no network at all, then go to ERROR, and nothing retries when the network returns (§10 left `NWPathMonitor` as an
option). A tunnel or underground car park takes longer than 15 s. Community practice (Apple networking guidance,
navigation and streaming apps, LiveKit client SDKs): watch the network path; while there is no network, wait instead of
counting failures; reconnect as soon as the path returns; keep a bounded retry budget only for failures with a working
network. Gemini Live resumption handles stay valid after a drop, so the conversation can continue. Owner 2026-10-30:
"just write spec to use this approach".

**Rule in plain words.** No signal is not an error: she shows 等待网络… and waits. When the signal comes back she
reconnects at once and the conversation continues. Only a server that keeps failing while the network works, or a
wrong key or quota, ends in an error.

1. **Network watcher (platform).** `NetworkPathWatcher` in `Packages/NovaPlatform/` wraps `NWPathMonitor` and emits
   `.networkLost` (path not `satisfied`) and `.networkRestored` (path `satisfied` again), debounced 500 ms so a quick
   Wi-Fi to cellular switch is not reported as lost. It runs only while a voice session exists. No import of Network
   outside NovaPlatform (`check_imports.py`).
2. **Session logic (NovaCore, pure).** `VoiceSession` takes the two events as inputs; no Network types in NovaCore.
   - **Offline while connected or reconnecting:** state RECONNECTING with `waitingForNetwork = true`. No connection
     attempts are made and none are counted against the 5-attempt budget. The dropped turn's reply audio is flushed
     (§8, epoch) as today.
   - **Network restored:** if `waitingForNetwork`, start one attempt at once (no backoff delay), with the resumption
     handle when there is one; the 5-attempt budget starts fresh from this point.
   - **Online failures:** unchanged §5/§9 policy (5 attempts, backoff, then ERROR). A failure while the watcher says
     online counts as today, even if the path is `satisfied` but the internet is unreachable (captive portal, VPN).
   - **Terminal errors** (auth, credential, quota/rate, malformed) go straight to ERROR as today; the network events
     never retry them.
   - **Start while offline:** tapping 开始对话 with no network enters RECONNECTING with `waitingForNetwork = true` and
     connects when the network returns, under the same cap (item 4).
3. **What the driver sees and hears.** While `waitingForNetwork`: chip amber 「等待网络…」 (instead of PROCESSING), no
   error sound, no spoken message. On reconnect the chip returns to 聆听中 and she does not mention the gap unless asked.
   If the handle is rejected (RESUME_UNAVAILABLE), a new session per §8: she does not claim to remember the lost turn.
   Local Mandarin subtitles (F-05a §12) may keep showing while offline; nothing is sent.
4. **Offline cap.** If the network stays gone for 10 minutes (`RealtimeTuning.offlineWaitCap`, default 600 s), the
   session ends quietly: microphone and audio session released, chip 「网络已断开，点按重新开始」, log
   `offlineCapReached`. Tapping starts a new session normally.
5. **Background.** If iOS suspends the app while waiting, nothing is required beyond today; on return to foreground with
   the network up, the same "network restored" path runs.
6. **Logs.** `networkLost`, `networkRestored`, `reconnectAttempt n reason=offlineRestore|backoff`, `resumed handle=yes|no`,
   `offlineCapReached`; no payloads, no keys.
7. **Depends on F-05 §14 (T-016g).** The ping double-callback crash must be fixed first or the app closes before this
   logic runs.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Scripted session: LISTENING, then `.networkLost`, then 60 s, then `.networkRestored` | RECONNECTING with `waitingForNetwork` for 60 s; zero attempts while offline; one immediate attempt on restore; resumes with the handle; LISTENING | unit (VoiceSession, fake clock) |
| 2 | Online socket drop, server keeps failing | Unchanged: 5 attempts with backoff, then ERROR | unit |
| 3 | `.networkLost` after 3 failed online attempts, then `.networkRestored` | Budget starts fresh: up to 5 more attempts | unit |
| 4 | Auth / quota error, then `.networkRestored` | Stays ERROR; no attempt | unit |
| 5 | Offline for longer than `offlineWaitCap` | Session ends; mic released; chip 「网络已断开，点按重新开始」; `offlineCapReached` | unit (fake clock) |
| 6 | Start while offline, network back after 30 s | Connects on restore without a tap | unit |
| 7 | Watcher: path unsatisfied for 300 ms then satisfied | No `.networkLost` emitted (debounce) | unit (fake path source) |
| 8 | Device: airplane mode on mid-conversation for 60 s, then off | Chip 「等待网络…」 the whole time, no crash, no 连接失败; reconnects within ~5 s of airplane mode off; next question answered | D |
| 9 | Device: walk into an underground car park or lift mid-conversation, then out | Same as row 8 | D |
| 10 | Device: airplane mode on, wait 11 minutes | Session ended, chip 「网络已断开，点按重新开始」; tap after airplane mode off starts normally | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-016h | §14 items 1–6: `NetworkPathWatcher` (NovaPlatform), `VoiceSession` offline wait / immediate restore / fresh budget / offline cap, chip texts, logs; unit rows 1–7; device rows 8–10 | unit, build, D (rows 8–10) |

## 15. After giving up, 你好小诺 connects again (iOS, APPROVED 2026-11-05)

**Why.** Owner 2026-11-05: once disconnected it does not connect back by itself. The 3 drops in the 8 records read (2026-11-04) all recovered in 2.1–6.0 s, so the owner's failure is not captured and its cause is not confirmed. The code at 21f4478 has this gap: with the phone reporting a network, the app makes 5 attempts with about 6 s of waiting in total, then goes to ERROR and keeps the session open. The wake listener stays off because `running` is still true, nothing retries, a tap on the talk button only stops the session, and the resumption handle has been deleted.

Owner's choice 2026-11-05: retry for a short time, then let the wake word connect again. Sources: [LiveKit Android](https://docs.livekit.io/reference/client-sdk-android/livekit-android-sdk/io.livekit.android.room.network/-default-reconnect-policy/index.html) stops retrying after up to 60 s; [Pipecat](https://docs.pipecat.ai/api-reference/server/services/s2s/gemini-live) stops after 3 failures in a row; [Gemini Live](https://aistudio.google.com/docs/live-api/session-management) resumption tokens are valid for 2 hours after a session ends. None of these test an in-car app, so rows 7–9 are the real test.

This section changes the online retry budget in §5, §9 and §14 item 2 ("5 attempts"), and the chip text in §14 item 4. It depends on T-060a for the wake word.

**Rule in plain words.** Retry by itself for up to 60 seconds. Then close the session and show why. 你好小诺 or a tap connects again and continues the conversation.

1. **The retry window.** With the phone reporting a network, a retryable failure keeps retrying until 60 s after the first failure (`ReconnectTuning.retryWindow`), with today's delays: 200 ms doubling to 8 s. There is no attempt limit. A completed setup clears the window. `networkRestored` starts it fresh, as §14 item 2 does for the budget.
2. **Giving up closes the session.** When the window ends, the session ends through the same path as the §14 item 4 offline cap: `stop()`, microphone and audio session released, `networkEnded` true. `running` becomes false, so the wake listener applies again. A trip keeps going as it does today.
3. **Terminal errors do not change.** Auth, credential, quota and malformed errors still go straight to ERROR. They are not retried and do not use this path.
4. **Keep the resumption handle.** On giving up, and at the offline cap, the runtime keeps the latest handle in memory with the time it was saved. It is never written to disk or logged (I-7). It is dropped when the driver stops the session, when the app process ends, and 2 hours after it was saved.
5. **Connecting again.** The next `start()`, from the wake word or a tap, uses a kept handle and then forgets it. If the server rejects it, `RESUME_UNAVAILABLE` starts a new session as §8 says, and she does not claim to remember.
6. **What the driver sees.** After giving up or the offline cap, the chip says 「连接断开，说“你好小诺”重连」 while the listener is armed, and 「连接断开，点按重连」 otherwise. A tap on the chip connects, as today. The text clears on the next start. No error sound and no spoken message.
7. **The ready sound.** F-01 §14 item 9 applies when the wake word starts this new session. Automatic reconnects inside the window have no sound.
8. **Seeing what happened.** Record lines: `session gave-up ms=<since first failure> attempts=<n> code=<last code>`, and `session resume handle=<yes|no> result=<resumed|rejected|none>` in the next session's record. `RuntimeLog` gets the same numbers and codes, never the handle (I-7).
9. **What this does not fix.**
   - A silently dead connection still takes 20–40 s to notice (`pingInterval` 20 s, plus up to 20 s for the pong). Until then the app counts as connected, so the wake word does not run.
   - With no working internet it still cannot connect. Saying 你好小诺 again later is the way back.
   - The wake word runs only with the app on screen (F-01 §13). In the background, the existing policy applies.
   - Words said while reconnecting are not replayed.
10. **Decision.** No pass bars. If the record shows the owner still gets stuck, the owner decides whether to change the 60 s.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Fake clock, retryable failures with the network reported up | Attempts continue with the delays capped at 8 s past 5 attempts; the last starts before 60 s; then give-up | unit |
| 2 | Failures for 30 s, then setup completes; then a new failure | No give-up; the window starts again from the new failure | unit |
| 3 | Failures for 50 s, then `networkLost`, later `networkRestored` | §14 waiting applies; the window starts fresh on restore | unit |
| 4 | Auth or quota error | ERROR at once; no retry and no kept handle | unit |
| 5 | Give-up with a handle | Session stopped, `running` false, `networkEnded` true, listener applied; the next start sends the handle once | unit |
| 6 | Kept handle and: the driver stops; 2 hours pass; the server rejects it | Not sent; not sent; a new session with no claim to remember | unit |
| 7 | Device: mid-conversation, join Wi-Fi with no internet or a hotspot with no data for 20 s, then restore | Reconnects by itself; the conversation continues; no chip message | D |
| 8 | Device: the same for over 60 s | The chip shows the message and `session gave-up` is recorded. Restore internet, say 「你好小诺」: it connects, the sound plays, and 「我刚才问什么」 gets an answer from before the drop. Note `session resume` | D |
| 9 | Device: the same as row 8, with a tap on the chip and with the wake setting off | Connects; the chip shows the tap text | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-016j | Items 1–10; rows 1–9 | unit, build, D |

## 16. Send the microphone to Gemini in 100 ms pieces (owner report 2026-11-07)

**Why.** Device 2026-11-07, 1f05a54, session 11:46:56, speaker lock on: the driver spoke for 5.6 s; the lock held the utterance until its end (F-04b §16 item 4) and accepted it at +17,959 ms (`waitMs=5090`). At +17,965 the session failed with `WS_FAILED`, the sentence was dropped (`sent=false`) and the screen showed a connection failure. Microphone audio goes to Gemini as one `realtimeInput` message per 10 ms frame, and `GeminiLiveProvider` ends the socket with `WS_FAILED` when more than `outboxLimit` (512) messages are queued. Releasing 5.6 s plus the 300 ms pre-roll at once queues about 590 messages, past the limit. Before F-04b §16 the hold was capped at 3 s (about 330 messages), so it never overflowed.

**Source.** Google's Live API guides say to send audio in chunks of 100 ms ([live transcription](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe), [live translation](https://ai.google.dev/gemini-api/docs/live-api/live-translate)).

1. **100 ms messages.** Between the uplink gate and `GeminiCodec.audio`, a pure `AudioChunker` in `NovaVoice` joins 10 ms frames into one message per 100 ms (1,600 samples, 3,200 bytes). It sends what it has early, without waiting for 100 ms, when the gate closes, at `activityEnd` or `audioStreamEnd`, before any non-audio message, and on mute, so nothing is reordered or lost. A held utterance released at once becomes about 60 messages.
2. **Not changed:** `outboxLimit` 512 and the `WS_FAILED` rule (a truly stalled writer still ends the socket), the audio format, the gate, the speaker hold, barge-in.
3. **Seeing why a session closes.** When the socket closes, `RuntimeLog` and the record get `session closed code=<WebSocket close code> reason=<first 80 chars of the close reason>`, so the closes seen every 2 minutes on 2026-11-07 (+154,893 and +276,569 ms, each reconnected in about 2 s) can be explained later. Nothing else changes for them.

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | 95 frames of 10 ms, then the gate closes | 9 messages of 100 ms, then 1 of 50 ms, in order, bytes unchanged | unit |
| 2 | Frames, then `activityEnd` after 30 ms of audio | The 30 ms goes out before `activityEnd` | unit |
| 3 | A held 5.6 s utterance plus 300 ms pre-roll released at once into a provider with `outboxLimit` 512 and a writer that does not write until all are queued | About 60 messages, no `WS_FAILED` | unit |
| 4 | The socket closes with code 1011 and a reason | `session closed code=1011 reason=...` in the log and the record | unit |
| 5 | Device, speaker lock on: say a 6–8 s sentence 5 times | Every one is sent and answered; no `WS_FAILED`; note any `session closed` lines and their codes | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-020b | Items 1–3; rows 1–5 (with F-07 §15) | unit, build, D |
