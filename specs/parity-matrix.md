# Feature parity matrix

Test types: **U** unit, **I** integration, **C** contract (recorded provider/API fixtures), **S**
simulator, **D** physical device, **M** manual. Priority: P0 = first vertical slice, P1 = core, P2 =
later. Every feature in feature-inventory.md appears here.

| ID | Feature | Android status | Android refs | Expected iOS behaviour | Required adaptation | Acceptance | Tests | Depends on | Pri | Unknowns / blockers |
|---|---|---|---|---|---|---|---|---|---|---|
| F-01 | Wake word | IMPLEMENTED | `A/wake/*` | Wake phrase starts/resumes listening (foreground) | New wake engine | features/wake-word.md §10 | U, D | F-03 | P2 | OQ-IOS-1, OQ-IOS-4 |
| F-02 | Listening lifecycle | ACTIVE | `ListeningLifecycle.kt` | Same states/timers | Port logic | §10 | U | — | P0 | — |
| F-03 | Capture + AEC | IMPLEMENTED | `PcmAudioCapture.kt`, `WebRtcAcousticEcho.kt` | 16 kHz clean frames during playback | AVAudioEngine voice processing | §10 | U (resampler), D | — | P0 | OQ-IOS-3 |
| F-04 | Uplink gate | ACTIVE | `SpeechUplinkGate.kt` | Same gating | Port DSP, re-tune | §10 | U (PCM corpus) | F-03 | P0 | thresholds on iOS mic |
| F-05 | Gemini Live session | ACTIVE | `GeminiLiveClient.kt` | Same protocol and event order | URLSession WebSocket | §10 | C, I, D | F-04 | P0 | OQ-IOS-5 |
| F-06 | Truthfulness gates | ACTIVE | `ActionClaimGuard.kt`, `DriverTurnPipeline.kt` | Same holds/corrections | Port logic | §10 | U, C | F-05, F-09 | P0 | — |
| F-07 | Azure TTS + playback | ACTIVE | `AssistantVoiceRevoicer.kt`, `AzureSpeechVoice.kt` | Same voice, clause order, epochs | AVAudioPlayerNode | §10 | U, I, D | F-03 | P0 | — |
| F-08 | Barge-in, arbitration | ACTIVE | `SpeechArbiter.kt` | Same priorities | Map iOS interruptions | §10 | U, D | F-07, F-14 | P1 | device latency target |
| F-09 | Tools + guards | ACTIVE | `ToolCallGuards.kt`, `ToolRegistry.kt` | Same names, schemas, guard order | Port logic | §10 | U (port Android tables) | — | P0 | — |
| F-10 | Ambiguity context | IMPLEMENTED | `ContextResolver.kt` | Same resolution | Port logic | §10 | U, D | F-09, F-11 | P1 | ASR mishearing |
| F-11 | Vehicle (simulated) | SIMULATED | `SimulatedVehicleControl.kt` | Same simulated state | Port logic | §10 | U (golden) | F-09 | P0 | — |
| F-12 | Comfort scenarios | IMPLEMENTED | `ComfortScenarios.kt` | Same steps | Port logic | §10 | U | F-11, F-13 | P1 | — |
| F-13 | Music | IMPLEMENTED | `BundledMusicPlayer.kt`, `media/*` | Bundled play/stop; named music via Apple Music only | MusicKit or drop | §10 | U, D | F-09 | P2 | OQ-IOS-7 |
| F-14 | Guidance relay | IMPLEMENTED | `GuidanceRelay.kt` | Prompts spoken once, no overlap | Amap iOS hooks | §10 | U, S, D | F-15, F-05 | P1 | OQ-IOS-2 |
| F-15 | Navigation flow | IMPLEMENTED | `EmbeddedNavigationController.kt` | Same phases, guards, cancel | Amap iOS adapter | §10 | U (fake engine), S, D | F-16 | P1 | OQ-IOS-2 |
| F-16 | Search, saved places | IMPLEMENTED | `LiveDestinationCandidateSource.kt` | Same queries/results | CLLocation + GCJ-02 | §10 | U, C (recorded Amap JSON) | — | P1 | — |
| F-17 | HUD, overspeed | IMPLEMENTED | `TextNavigationPanelModel.kt`, `OverspeedAlert.kt` | Same panel text, alert rule | Amap iOS nav info | §10 | U, S | F-15 | P1 | OQ-IOS-2 |
| F-18 | Live info | IMPLEMENTED | `LiveInfoTool.kt` | Same answers/refusals | HTTP | §10 | U, C | F-16 | P1 | — |
| F-19 | Phone call | IMPLEMENTED | `PhoneCallTool.kt` | Confirm then dial | Contacts + tel URL | §10 | U, M | F-09 | P2 | extra system sheet |
| F-20 | Vision | IMPLEMENTED | `vision/*` | Same Q&A | AVCapture | §10 | U, D | F-09 | P2 | — |
| F-21 | Persona, style | IMPLEMENTED | `PersonaProfiles.kt` | Same styles | Port | §10 | U | F-05 | P1 | — |
| F-22 | Settings, secrets | IMPLEMENTED | `DeveloperSettingsActivity.kt` | Same cards (Gemini, Azure, Amap, wake, vision) | SwiftUI + Keychain | §10 | U, S | — | P0 | — |
| F-23 | Lifecycle, permissions | IMPLEMENTED | `MainActivity.kt`, `VoiceSessionService.kt` | Documented background policy | Background audio mode | §10 | D, M | — | P1 | OQ-IOS-4 |
| F-24 | Network recovery | IMPLEMENTED | `ReconnectPolicy.kt` | Same retry policy | — | §10 | I (fake server) | F-05 | P0 | — |
| F-25 | Main screen + overlays | IMPLEMENTED | `ui/*` | Same chip/bubble/choice list | SwiftUI | §10 | U, S | F-15 | P1 | — |
| V-LAT | End-of-speech → first audio | P48: 2.6–4.2 s EMU | contracts/voice-agent.md | ≤ Android baseline on the same network | measure | median ≤ 3.0 s over 20 device turns (PROPOSED target) | D | F-05, F-07 | P1 | no device baseline exists |

## Given/When/Then: key voice workflows

**W1 normal turn.** Given ACTIVE and connected, when the driver says 「打开空调」, then exactly one
`control_climate` call executes, its result is ok, and only then 「空调开了…」 is heard and subtitled.

**W2 interruption.** Given she is speaking clause 2 of 3, when the driver starts speaking, then
playback stops (epoch flushed), clause 3 is never played, and the driver's words reach the model.

**W3 timeout.** Given the driver finished speaking, when no model output arrives within 3 s, then one
re-ask 「请回应我刚才说的话。」 is sent; when still nothing by 5 s, she gives up silently and a late tool
call from that turn is dropped.

**W4 failure recovery.** Given a turn in progress, when the socket drops (retryable), then the UI shows
PROCESSING, the session reconnects with the resumption handle within 5 attempts, and the next driver
turn works without re-entering settings.

**W5 concurrent events.** Given navigation is running, when a guidance prompt and a reply are ready at
the same time, then guidance plays first, the reply is held (R1) and plays after guidance + 500 ms tail;
nothing overlaps.

**W6 ambiguity.** Given temperature and seat were both changed within 180 s, when the driver says
「再低一点」, then no tool executes and she asks 「是座椅还是温度？」; when the driver answers 「座椅」, then
`control_seat adjust_height −1` executes once.

**W7 false claim.** Given the model says 「导航已开始」 while the phase is AWAITING_ROUTE_SELECTION, then
the line is not heard and a correction is sent (`NAVIGATION_NOT_STARTED`).

**W8 cancel race.** Given a route calculation is in flight, when the driver says 「算了」, then phase is
IDLE, and the late `onCalculateRouteSuccess` changes nothing and draws no route.
