# Feature specifications

One file per feature. Load one file plus the contracts it lists under "Depends on".

| ID | Feature | Android status |
|---|---|---|
| F-01 | [Wake word](wake-word.md) | IMPLEMENTED (iFlytek MSC, offline) |
| F-02 | [Listening lifecycle and local phrases](listening-lifecycle.md) | ACTIVE (JVM-tested; EMU) |
| F-03 | [Microphone capture, AEC and gain](audio-capture-aec.md) | IMPLEMENTED; AEC delay/echo device rows NOT_RUN (ECHO-001, AEC-DELAY-DEVICE-001) |
| F-04 | [Uplink gate (local VAD)](uplink-gate.md) | ACTIVE (JVM + EMU) |
| F-05 | [Realtime session (Gemini Live)](realtime-session.md) | ACTIVE provider |
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
| F-16 | [Destination search and saved places](destination-search.md) | IMPLEMENTED (JVM + LIVE Amap Web) |
| F-17 | [Navigation HUD and overspeed alert](hud-overspeed.md) | IMPLEMENTED (JVM + EMU) |
| F-18 | [Live info: weather, route traffic, along-route, place details](live-info.md) | IMPLEMENTED (JVM + EMU live shards ≥9/10) |
| F-19 | [Phone call with confirmation](phone-call.md) | IMPLEMENTED (JVM) |
| F-20 | [Camera vision questions](vision.md) | IMPLEMENTED (JVM) |
| F-21 | [Persona and speaking style](persona-style.md) | IMPLEMENTED (JVM + LIVE 5/5) |
| F-22 | [Settings, credentials and consent](settings-credentials.md) | IMPLEMENTED |
| F-23 | [App lifecycle, background and permissions](app-lifecycle-permissions.md) | IMPLEMENTED: foreground service type microphone, START_NOT_STICKY; no boot start; no accessibility service |
| F-24 | [Network recovery](network-recovery.md) | IMPLEMENTED (JVM; fault injection `NetworkFaults |
| F-25 | [Main screen, assistant overlay and choice overlay](ui-overlay.md) | IMPLEMENTED (JVM for models; EMU screenshots) |
