# Feature inventory

Verified against code on 2026-10-22 (see features/ for each). Requested items that were checked and
found absent or different are listed at the bottom.

## Active and implemented

| ID | Feature | Status | Proof level (Android) |
|---|---|---|---|
| F-01 | Wake word (iFlytek MSC, offline) | IMPLEMENTED | DEVICE (2026-09-19), engine rows NOT_RUN |
| F-02 | Listening lifecycle + local phrases | ACTIVE | JVM, EMU |
| F-03 | Mic capture, WebRTC AEC3, gain | IMPLEMENTED | JVM; echo device rows NOT_RUN |
| F-04 | Uplink gate (local VAD) | ACTIVE | JVM, EMU |
| F-05 | Realtime session — Gemini Live | ACTIVE | JVM, EMU, LIVE |
| F-06 | Reply truthfulness gates | ACTIVE | JVM, LIVE |
| F-07 | Azure TTS revoicing + playback | ACTIVE when configured | JVM, EMU |
| F-08 | Barge-in and speech arbitration | ACTIVE | JVM, EMU; device latency HUMAN |
| F-09 | Tool catalog, dispatch, guards | ACTIVE | JVM, LIVE |
| F-10 | Driver context, ambiguity | IMPLEMENTED | JVM; FZ-14 not proven in a recording |
| F-11 | Vehicle controls | SIMULATED | JVM, LIVE text |
| F-12 | Comfort scenarios | IMPLEMENTED | JVM, LIVE text |
| F-13 | Music (bundled + media-session search) | IMPLEMENTED | JVM; play_music not exercised on EMU |
| F-14 | Guidance voice relay | IMPLEMENTED | JVM, EMU; P46 open |
| F-15 | Navigation flow | IMPLEMENTED | JVM, EMU |
| F-16 | Destination search, saved places | IMPLEMENTED | JVM, LIVE |
| F-17 | HUD, overspeed | IMPLEMENTED | JVM, EMU; overspeed not observable in CI |
| F-18 | Live info | IMPLEMENTED | JVM, EMU live shards |
| F-19 | Phone call with confirmation | IMPLEMENTED | JVM; device NOT_RUN |
| F-20 | Vision | IMPLEMENTED | JVM |
| F-21 | Persona and speaking style | IMPLEMENTED | JVM, LIVE |
| F-22 | Settings, credentials, consent | IMPLEMENTED | JVM |
| F-23 | Lifecycle, background, permissions | IMPLEMENTED | mostly HUMAN/NOT_RUN |
| F-24 | Network recovery | IMPLEMENTED | JVM |
| F-25 | Main screen and overlays | IMPLEMENTED | JVM, EMU |

## Tool catalog (shared by F-09 and all executors)

| Tool | Args (* required) | Feature |
|---|---|---|
| `navigate_to` | destination* (≤120) | F-15 |
| `choose_navigation_option` | index ≤10 / preference / name (exactly one) | F-15 |
| `exit_navigation_mode` | — | F-15 |
| `save_place` | slot* {home, work}, address* | F-16 |
| `open_app` | app* {maps, settings} | F-25 |
| `control_music` | action* {play, stop} | F-13 |
| `play_music` | free-text fields, ≥1 non-blank | F-13 |
| `control_climate` | action*, value | F-11 |
| `control_window` | action* {open, close, set, adjust, get_state}, window, value | F-11 |
| `control_seat` | action* {adjust_height, set_height, get_state}, seat, value | F-11 |
| `run_scenario` | name* {mosquito, mosquito_done, stuffy, drowsy} | F-12 |
| `describe_camera_view` | question* | F-20 |
| `place_call` | contact*, confirmed | F-19 |
| `query_live_info` | kind*, where, day, category, target | F-18 |
| `end_conversation` | — | F-02 |
| `set_speech_output` | mode* {silent, spoken} | F-02 |
| `set_speaking_style` | style* {sweet, tsundere, gentle, lively, default} | F-21 |

Exact `control_climate` action enum (`ClimateToolHandler.ACTIONS`) and the choice tool's field details:
UNVERIFIED in detail — copy from `A/vehicle/ClimateToolHandler.kt:102` and `A/tools/NavigationDomain.kt:76`
when implementing (allowed Android lookup, see ai-agent-workflow.md).

## Dormant, deprecated, dead (do not port)

| Item | State | Evidence |
|---|---|---|
| Qwen-Omni provider | FROZEN by owner 2026-10-22 | `VoiceProviderChoice.QWEN_FROZEN` |
| Baidu Realtime Flex / Lite | DORMANT (ADR-002 deprecated in practice) | `RealtimeProviderFactory` branches never selected |
| GPT_LIVE / OpenAI | NOT RUNNABLE (catalog id only) | no factory branch |
| `VoiceCatalog.DEFAULT_PROVIDER = BAIDU_FLEX` | STALE constant | `I/VoiceCatalog.kt:110` |
| `AecMetrics.shouldFlushBargeIn` | DEAD | no callers |
| `PhaseOneNavigationController`, `NavigationAutoPick` | DEAD | not referenced in main |
| `automotive_app_desc.xml` | placeholder, not wired | manifest |
| Debug broadcast receiver, host audio bridge | test rig only | `src/debug/` |

## Requested items checked and found different

- **Local ASR:** none. Transcripts come from Gemini input transcription.
- **Location "saved destinations":** only home/work slots.
- **Accessibility service, boot start:** not present.
- **Real vehicle API:** not present (simulated).
- **Music via other apps:** Android media-session mechanism; no iOS equivalent for third-party apps.
