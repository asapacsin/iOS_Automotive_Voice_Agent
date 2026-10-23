# Migration plan

## Recommended iOS repository structure (PROPOSED)

```
NovaDriveIOS/
├── AGENTS.md                      # minimal, see ai-agent-workflow.md
├── specs/                         # copy of docs/ios-port (versioned, with SPEC_VERSION)
├── Packages/
│   ├── NovaCore/                  # pure Swift, no UIKit/AVFoundation: lifecycle, gate, guards,
│   │                              #   context, truthfulness, navigation phase machine, tool registry
│   ├── NovaRealtime/              # provider contract + Gemini Live adapter (Foundation only)
│   ├── NovaAudio/                 # AVAudioEngine capture/playback, resampler, epochs
│   ├── NovaNavAmap/               # Amap SDK adapter (only module importing Amap, I-9)
│   └── NovaServices/              # Azure TTS, Amap Web, Qianfan, Keychain, simulated vehicle
├── App/                           # SwiftUI app, settings, overlay
└── Tests/                         # mirrors Packages; fixtures/ holds recorded Gemini + Amap JSON
```

`NovaCore` is where most Android logic (class A) lands; it must build and test on macOS without a
simulator, so Executors can iterate fast.

## Smallest useful end-to-end vertical slice (M1)

**"Talk to 小诺 and turn on the (simulated) AC, truthfully."** In the foreground on a physical iPhone:
1. Settings: enter Gemini key + consent, Azure key (F-22).
2. Tap to talk (no wake word yet).
3. Capture 16 kHz with voice processing (F-03), uplink gate (F-04).
4. Gemini Live session with the full tool catalog declared but only `control_climate`, `control_seat`,
   `control_window` executed (simulated, F-11); other tools return a deterministic "not yet" error.
5. Truthfulness gate (F-06): claims held until ok results.
6. Azure TTS + playback with epochs; barge-in stops playback (F-07, F-08 minimal).
7. Status chip + bubble (F-25 subset).

M1 acceptance: W1, W2, W3, W4 pass on a device; unit suites for F-02/F-04/F-06/F-09/F-11 pass in CI.

## Milestones (each independently testable)

| M | Scope | Exit criteria |
|---|---|---|
| M0 | Device spike for OQ-IOS-3 (voice-processing AEC quality on an iPhone) and an Amap iOS hello-route (confirm the route-select call). OQ-IOS-2, 4, 5 are answered from documentation (2026-10-23) | Spike results in open-questions.md; go/no-go per subsystem |
| M1 | Vertical slice above | W1–W4 on device |
| M2 | Full tools without navigation: comfort scenarios, ambiguity, persona/style, live weather, music (bundled) | F-10/F-12/F-18 (weather)/F-21 unit + device W6 |
| M3 | Navigation core: search, pick, route, start, cancel, HUD on Amap iOS; guards while navigating | W8; F-15/F-16/F-17 unit + simulator drive |
| M4 | Guidance relay + arbitration with navigation; overspeed | W5; F-14 device |
| M5 | Wake word, listening lifecycle with sleep/deep-idle, background policy | F-01/F-23 device |
| M6 | Phone, vision, named music (MusicKit if approved) | F-19/F-20/F-13 |
| M7 (optional) | CarPlay app in ONE category: navigation or voice-based conversational (OQ-IOS-8, owner) | entitlement granted; CarPlay Simulator test |

## Specification drift control

- `docs/ios-port/SPEC_VERSION` (add when the iOS repo is created) records the Android commit this spec
  was written from (`bf81876` + this docs commit).
- A drift check (proposed script): for every `A/...:line` reference, verify the symbol still exists in
  the Android repo at HEAD; list features whose referenced files changed since SPEC_VERSION. Run weekly
  or before each iOS milestone; changed features are re-reviewed, not silently copied.
