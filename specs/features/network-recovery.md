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
