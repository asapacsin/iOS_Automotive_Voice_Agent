# Feature specifications

One file per feature. Load one file plus the contracts it lists under "Depends on".

| ID | Feature | Android status |
|---|---|---|
| F-01 | [Wake word](wake-word.md) | IMPLEMENTED (iFlytek MSC, offline) |
| F-02 | [Listening lifecycle and local phrases](listening-lifecycle.md) | ACTIVE (JVM-tested; EMU) |
| F-03 | [Microphone capture, AEC and gain](audio-capture-aec.md) | IMPLEMENTED; AEC delay/echo device rows NOT_RUN (ECHO-001, AEC-DELAY-DEVICE-001) |
| F-04 | [Uplink gate (local VAD)](uplink-gate.md) | ACTIVE (JVM + EMU) |
| F-04a | [Noise suppression: only a human voice opens the mic or interrupts](noise-suppression.md) | iOS only, APPROVED (2026-10-27); tasks T-013a–d |
| F-05 | [Realtime session (Gemini Live)](realtime-session.md) | ACTIVE provider |
| F-05a | [Mandarin input transcript on the phone (普通话识别，不再被当成葡萄牙语)](mandarin-transcript.md) | iOS only, DRAFT (2026-10-29); tasks T-016a–c |
| F-06 | [Reply pipeline and truthfulness gates](reply-truthfulness.md) | ACTIVE (JVM + LIVE suites) |
| F-07 | [Assistant voice (Azure TTS) and playback](tts-playback.md) | ACTIVE when an Azure voice is configured (ADR-016) |
| F-08 | [Barge-in and speech arbitration](barge-in-arbitration.md) | ACTIVE (JVM; EMU; device latency HUMAN) |
| F-09 | [Tool catalog, dispatch and guards](tool-dispatch-guards.md) | ACTIVE (JVM + LIVE) |
| F-10 | [Driver context and ambiguity resolution](ambiguity-context.md) | IMPLEMENTED (JVM); FZ-14 clarification not yet proven in a recording (runs 298, 317, 319) |
| F-11 | [Vehicle controls (simulated)](vehicle-controls.md) | IMPLEMENTED, SIMULATED ONLY (no VHAL/CarPropertyManager) |
| F-12 | [Comfort scenarios](comfort-scenarios.md) | IMPLEMENTED (JVM + LIVE text) |
| F-13 | [Music](music.md) | IMPLEMENTED: bundled track play/stop; media-session search + read-back (SPEC-017, play_music path not exercised in demo run 315) |
| F-14 | [Navigation guidance voice (relay)](guidance-voice.md) | IMPLEMENTED (JVM; EMU with real Gemini) |
| F-15 | [Navigation flow (search → pick → route → navigate → cancel)](navigation-flow.md) | IMPLEMENTED (JVM + EMU, Amap Navi SDK 11 |
| F-15a | [Real navigation by default, simulation as a separate mode (真实导航 / 模拟导航)](navigation-modes.md) | iOS only, DRAFT (2026-10-29); tasks T-040a–d |
| F-16 | [Destination search and saved places](destination-search.md) | IMPLEMENTED (JVM + LIVE Amap Web) |
| F-16a | [Use the phone's real location (位置来源, 「我现在在哪？」)](current-location.md) | iOS only, APPROVED (2026-10-27); tasks T-042a–b, T-046a |
| F-16b | [Show the driver's current position on the map (我的位置)](map-current-location.md) | iOS only, APPROVED (2026-10-29); tasks T-044a–c |
| F-16b.1 | [Map position logic (marker rules, camera policy)](map-logic.md) | iOS only, APPROVED (2026-10-29); task T-044a |
| F-17 | [Navigation HUD and overspeed alert](hud-overspeed.md) | IMPLEMENTED (JVM + EMU) |
| F-18 | [Live info: weather, route traffic, along-route, place details](live-info.md) | IMPLEMENTED (JVM + EMU live shards ≥9/10) |
| F-19 | [Phone call with confirmation](phone-call.md) | IMPLEMENTED (JVM) |
| F-20 | [Camera vision questions](vision.md) | IMPLEMENTED (JVM) |
| F-20a | [Camera button, live preview window and “what is there?” questions](camera-view.md) | iOS only, APPROVED (2026-10-26); tasks T-071a–d |
| F-20b | [Rear view in the camera window (前方 / 后方 switch)](camera-rear.md) | iOS only, APPROVED (2026-10-27); tasks T-071e–g |
| F-21 | [Persona and speaking style](persona-style.md) | IMPLEMENTED (JVM + LIVE 5/5) |
| F-22 | [Settings, credentials and consent](settings-credentials.md) | IMPLEMENTED |
| F-23 | [App lifecycle, background and permissions](app-lifecycle-permissions.md) | IMPLEMENTED: foreground service type microphone, START_NOT_STICKY; no boot start; no accessibility service |
| F-24 | [Network recovery](network-recovery.md) | IMPLEMENTED (JVM; fault injection `NetworkFaults |
| F-25 | [Main screen, assistant overlay and choice overlay](ui-overlay.md) | IMPLEMENTED (JVM for models; EMU screenshots) |
