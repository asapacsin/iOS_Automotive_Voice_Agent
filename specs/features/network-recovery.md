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

## 15. See through the VPN, keep trying through a route change (iOS, APPROVED 2026-10-31)

**Why.** Device run ac53787 (2026-10-31, checklist 10-02, VPN on; Gemini needs a VPN in China): after airplane mode
was turned off the app showed 连接失败 instead of reconnecting. Log (syslog 15:38–15:41):
- **The watcher never fired.** Zero `networkLost` / `networkRestored` lines. NovaDrive's traffic runs over the VPN
  tunnel (`utun5`), and the tunnel path stays `satisfied` when the real network under it goes away. The path
  description shows the gap: normally `interface: utun5 … uses wifi` (or `uses cell`); at 15:38:30–15:38:34 (airplane
  mode on) and at 15:40:19.6 (airplane mode off, 0.7 s before the drop) it was `interface: utun5, ipv4, dns` with no
  `uses wifi` / `uses cell`. §14 item 1 checks only `status == .satisfied`, so both gaps counted as "online".
- **Retries ran out during the route change.** 15:40:17 airplane mode off; 15:40:20 TCP reset (`ECONNRESET`) while the
  VPN moved to the new route; three attempts got HTTP 101 and were closed about 0.5–1 s later (`provider failed
  CONNECTION_CLOSED` 15:40:24, 15:40:30, 15:40:35); the 5-attempt budget (§5/§9, about 15 s) ended in ERROR at
  15:40:35 while the path was already back (`uses wifi` again from 15:40:23.8).
- **The close reason is not logged,** so whether Gemini refused the resumption handle or the VPN dropped the new
  socket cannot be told. `GeminiCloseClassifier` maps only the recorded 1008 "session not found" to
  `RESUME_UNAVAILABLE`; these closes were not that one.
- **Dead sockets are noticed late.** `RealtimeTuning.pingInterval` is 20 s with a one-interval pong deadline, so a
  black-holed socket can take up to 40 s to be closed.
Community review 2026-10-31: Apple DTS: `NWPathMonitor` can give false positives and negatives and is advisory only;
watch the path that actually carries the traffic; VPN paths report the real interface separately
(`usesInterfaceType`). Realtime clients (WebSocket guides, y-websocket on iOS, LiveKit with Gemini Live) use an
application heartbeat to detect a dead connection, back off with a time window rather than a few quick tries, and start
a fresh session when resuming keeps failing (Gemini Live forum reports: resume after a drop closed at once with
1007/1011). Owner 2026-10-31: "Yes, spec it".

**Rule in plain words.** A VPN that says "connected" with no Wi-Fi or mobile data under it is no network: she shows
等待网络… and waits. A network change is given about a minute to settle before anything is called an error, and if
resuming keeps being refused she starts a fresh session instead of giving up.

1. **Network means a real interface (platform).** `NetworkPathWatcher` reports available only when the path is
   `satisfied` **and** uses Wi-Fi, cellular or wired Ethernet (`usesInterfaceType(.wifi / .cellular /
   .wiredEthernet)`). A satisfied path with only a tunnel or other interface counts as unavailable. The decision is a
   pure function in NovaKit over a snapshot (`NetworkPathSnapshot(satisfied:, wifi:, cellular:, wired:, other:)`), so
   it is unit-tested without the Network framework; the 500 ms debounce (§14 item 1) is unchanged. A tuning switch
   `RealtimeTuning.requirePhysicalInterface` (default true) turns the extra check off if a device misreports.
   Each change logs `networkPath satisfied=<bool> via=wifi|cell|wired|none tunnel=<bool>` (no addresses, no names).
2. **Unreachable is not a server failure (NovaCore).** A failure is *unreachable* when no server close frame was
   received: `CONNECTION`, `DNS`, `TIMEOUT` (connect or setup), or a socket closed with 1006 / no close frame,
   including a ping timeout. It is a *server close* when the socket got HTTP 101 and then a close frame with a code.
   The close classifier carries this as a flag on the failure; `VoiceSession` stays pure.
3. **Retry window instead of 5 quick tries.** This replaces "online failures: unchanged" of §14 item 2 and the
   5-attempt limit of §5/§9 for retryable failures. For retryable failures the budget is both at least 5 attempts and at
   least `ReconnectTuning.retryWindow` (default 60 s) from the first failure of the run, with the existing backoff
   (200 ms doubling, 8 s cap: about 11 attempts in 60 s). When the window ends:
   - all failures of the run were *unreachable* → RECONNECTING with `waitingForNetwork` (§14 chip 「等待网络…」),
     plus one probe attempt every `ReconnectTuning.probeInterval` (default 15 s) that is not counted, until a probe
     reaches setupComplete, the watcher reports restored (immediate attempt as §14), or the §14 offline cap ends the
     session;
   - otherwise (the server keeps closing a working connection) → ERROR as today.
   Terminal errors (auth, credential, quota/rate, malformed) still go straight to ERROR. A restore, a setupComplete or
   a change of `via` (Wi-Fi ↔ cellular) starts the window fresh.
4. **Faster dead-socket check.** `pingInterval` 10 s and a separate `pongTimeout` 5 s (`RealtimeTuning`), so a dead
   socket is closed within 15 s. A ping timeout is *unreachable* (item 2).
5. **Fresh session when resuming keeps failing.** If two attempts in a row that resume with a handle are closed by the
   server before setupComplete, or within 3 s after it, the handle is dropped and the next attempt opens a new session
   (log `resumeDropped reason=quickClose`). She then behaves as for `RESUME_UNAVAILABLE` (§14 item 3): no claim to
   remember the lost turn. The recorded 1008 "session not found" still drops it at once.
6. **Close details in the log.** Every socket end logs `providerClosed code=<int> reason=<text, max 120 chars>
   http=<status|none> afterSetup=yes|no resumed=yes|no openMs=<ms since open> kind=unreachable|server`. The reason is
   the server's close text only; never the URL, query, headers or key (I-7).
7. **Not in scope.** The degraded answers after the resume at 15:38:41 (「我在哪」 unanswered, `turnUnanswered`,
   `correctionSent`, `classifierMax` stuck at 0.28 for every later utterance) happened with the network up and are a
   separate investigation; the `toolCall` diagnostic of F-21 §15 (T-034b) will show whether the location tool ran.
   The VPN app itself is not controlled by NovaDrive.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Snapshots: satisfied + wifi; satisfied + cellular; satisfied + wired; satisfied + other only; unsatisfied + wifi | available, available, available, unavailable, unavailable; with `requirePhysicalInterface = false` the 4th is available | unit (NovaKit) |
| 2 | Watcher fed satisfied+wifi, then satisfied+other only for 300 ms, then for 600 ms | No report for the 300 ms gap; `.networkLost` for the 600 ms gap, then `.networkRestored` | unit (fake path source, fake clock) |
| 3 | Scripted: server-close failures (101 + code 1011) for 70 s | Attempts continue with backoff past attempt 5 until 60 s, then ERROR | unit (VoiceSession, fake clock) |
| 4 | Scripted: unreachable failures (CONNECTION / ping timeout) for 70 s | After 60 s: RECONNECTING `waitingForNetwork`, chip 「等待网络…」; probes every 15 s, uncounted; a probe succeeding → LISTENING | unit |
| 5 | Scripted: auth error | ERROR at once; no window, no probe | unit |
| 6 | Scripted: two resumed attempts closed 0.5 s after 101 | Third attempt sends no handle; `resumeDropped reason=quickClose`; after setupComplete she does not claim the lost turn | unit (VoiceSession + provider fake) |
| 7 | Provider: socket closed with code 1011 reason "x", and one with no close frame | `providerClosed` lines with code, reason, `kind=server` / `kind=unreachable`; no URL or key in either | unit (log capture) |
| 8 | Provider: no pong for 5 s | Socket closed as unreachable within 15 s of the last pong | unit (fake connection) |
| 9 | Device, VPN on: checklist 10-02 (airplane mode on mid-conversation, then off, then 「我在哪」) | `networkLost` / `networkRestored` logged; chip 「等待网络…」, never 连接失败; reconnects without a tap; `providerClosed` lines show the close codes | D |
| 10 | Device, VPN on: walk from Wi-Fi to cellular (leave the building) mid-conversation | Reconnects within the window; no 连接失败 | D |
| 11 | Device, VPN on: normal 10-minute conversation | No spurious `networkLost`; no extra reconnects | D (log) |
| 12 | Device, VPN off (Wi-Fi only, if reachable): §14 rows 8–10 | Still pass | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-016i | §15 items 1–6: physical-interface check (pure snapshot function, tuning switch, `networkPath` log), unreachable vs server-close flag, 60 s retry window and probe wait, ping 10 s / pong 5 s, drop the handle after two quick closes, `providerClosed` log; unit rows 1–8; device rows 9–12 | unit, build, D (rows 9–12) |
