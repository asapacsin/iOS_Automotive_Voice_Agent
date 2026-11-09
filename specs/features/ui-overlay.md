# F-25 Main screen, assistant overlay and choice overlay

**Android status:** IMPLEMENTED (JVM for models; EMU screenshots).
**Depends on:** contracts/voice-agent.md §1, contracts/navigation.md

## 1. Purpose
Full-screen map with a small assistant bubble (latest exchange only), a status chip, a navigation choice list, and on-screen affordances.

## 2. User-facing behaviour
Bubble shows 你: … / 小诺: …, fades by itself; chip 聆听中 / PROCESSING (amber) / SPEAKING; choice overlay lists candidates/routes; tapping = same executor as voice (I-6).

## 3. Preconditions
None for the screen; a session for the bubble and chip; navigation for the list and HUD.

## 4. Inputs and outputs
- In: session UI state, latest user transcript and reply text, navigation snapshot (places, routes, phase,
  HUD), simulated car position.
- Out: status chip, bubble (你: … / 小诺: …, latest exchange only), choice list rows, map overlays,
  camera icon and preview window (F-20a). Accessibility identifiers (e.g. `status-chip`) for UI tests.

## 5. State transitions
Chip mapping (contracts/voice-agent.md §1): DISCONNECTED→IDLE; CONNECTING/RECONNECTING/THINKING→PROCESSING
(amber); LISTENING/USER_SPEAKING→聆听中; SPEAKING→SPEAKING; ERROR→ERROR (+ code). The list is visible while
the phase is awaitingDestinationSelection or awaitingRouteSelection; a route line is drawn only for offered
or chosen routes, never after cancel.

## 6. Events and triggers
Session state changes, transcripts, navigation snapshot publishes, taps (row, 开始/结束对话, camera).

## 7. Dependencies and external services
SwiftUI `DriveView` over the map (Amap map view later, T-044); `AgentRuntime` composition root.

## 8. Error handling and recovery
- The error chip shows the session error code so device runs can be diagnosed.
- A tap on a row calls the same executor as the voice choice (I-6) and gets the same codes (`OPTIONS_STALE`, …).

## 9. Concurrency, cancellation, timeouts
All view state updates on the main actor; the bubble fades on its own (`BubbleFadeTuning`, iOS values); a new
exchange replaces the bubble at once.

## 10. Acceptance criteria (iOS)
- Chip mapping identical (unit).
- A tap on a choice row calls the same executor as the voice choice (unit).
- Bubble holds 4 s + 120 ms per character (max 10 s), never while speaking, then fades over 500 ms; a
  new exchange replaces it at once (unit; iOS values, owner decision 2026-10-26, no Android parity).
- `open_app` maps/settings switches the screen and the reply comes from the screen read back; an
  unknown app is `APP_NOT_ALLOWED`; a switch that did not happen is `APP_NOT_OPENED`, never claimed (unit, PROPOSED iOS row).

## 11. Existing Android tests
`T/ui/AssistantUiStateMapperTest`, `TranscriptBubbleFadeTest`, `TranscriptBubbleSessionSimulationTest`, `RecentTranscriptTest`, `ShownErrorCardTest`, `AffordanceMatcherTest`, `ScreenAffordanceRunnerTest`.

## 12. Source references (Android)
`A/ui/AssistantNavigationScreen.kt`; `A/ui/AssistantOverlayView.kt:310,446`; `A/ui/AssistantUiStateMapper.kt:6-25`; `A/ui/NavigationChoiceOverlay.kt`; `A/NavigationChoiceAction.kt`; `A/ui/TranscriptBubbleFade.kt`; `A/ui/ScreenAffordances.kt`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
SwiftUI over the Amap map view (B).

## 14. Remove unused code; test screens out of the driver's tab bar (iOS, APPROVED 2026-11-09)

**Why.** Owner 2026-11-09: clear the code that is built but not used. A check of `claude/t-020a-qwen-tts` at 2a35f02 found:
- `MusicKitPlayer` (`Packages/NovaPlatform/Sources/NovaPlatform/Music/`): created by nothing since OQ-IOS-7; named music now uses `ITunesPreviewMusic` (F-13 §14).
- The CarPlay scene (`App/NovaDrive/CarPlay/`): inert, CarPlay skipped (OQ-IOS-8, T-080 NOT_APPLICABLE).
- 「音频测试」 (`AudioSpikeView`, `EchoSpike`) and 「录制」 (`RecorderView`, `GeminiRecorder`): measurement screens shown as tabs next to 驾驶. They are still named by F-08 (T-001a) and F-21, so they are kept and moved, not deleted.
- Not debt, kept as they are: Azure and Qwen voices and the Azure `express-as` style (wired through `SpeakingStyle.saved`), `ComfortEvalRunner` and `ComfortEvalView` (comfort tests use them).

1. **MusicKit.** Delete `MusicKitPlayer.swift` and anything that only it uses. Remove MusicKit from `App/project.yml` and the entitlements if it is listed there. The `NamedMusicPort` comment says 「iTunes previews (F-13 §14)」 instead of Apple Music.
2. **CarPlay.** Delete `App/NovaDrive/CarPlay/`, its scene entry and its entitlement, if present. Remove `"CarPlay"` from `scripts/gates/check_imports.py`. The `DriveView` comment no longer mentions the CarPlay scene.
3. **Tabs.** The tab bar is 驾驶, 车辆, 设置. `AppTab` loses `audio` and `recorder`. 设置 → 开发 gets two rows, 「音频测试」 and 「录制」, which open the same screens as before.
4. **Records.** In `specs/STATUS.md`, T-072 and T-080 become REMOVED with the commit.
5. **Not changed:** music (F-13 §14), voices, comfort tests, the recorder's and audio test's behaviour.

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Source tree after the change | No `MusicKitPlayer`, no `import MusicKit`, no `import CarPlay`, no `CarPlaySceneDelegate`; `scripts/gates/run_all.sh` green | unit (gate) |
| 2 | App build | Builds; tabs are 驾驶, 车辆, 设置 | build |
| 3 | Device: open the app | Three tabs; 设置 → 开发 has 「音频测试」 and 「录制」, each opens and works as before | D |
| 4 | Device: 「放 Kalafina 的 oblivious」 | Plays as F-13 §14 (named music unaffected) | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-090 | Items 1–5; rows 1–4 | unit, build, D |
