# Nova Drive iOS — December 4, 2026 delivery plan

**Plan version:** 2026-10-26  
**Timezone:** Asia/Macau (UTC+08:00). Every date below is a local date.  
**Deadline:** **Friday, 2026-12-04**  
**Source of truth for work execution:** [work.json](work.json) and [STATUS.md](STATUS.md).  
**Planning trackers:** GitHub weekly release issues linked below.

## Definition of the deliverable

Deliver a **functional iPhone-first Nova Drive (小诺) MVP**, not a test screen or a demo assembled from isolated mocks. The required vertical product loop is:

1. Driver speaks Mandarin in a live realtime Gemini voice session (not a three-stage ASR→LLM→TTS architecture).
2. Speech-triggered action goes through the **same** guarded tool dispatcher as UI intents.
3. A model cannot claim an action succeeded before verified tool/action state; simulated vehicle controls must be labeled simulated.
4. Driver can search an actual POI, choose candidate and route, start/cancel Amap navigation, and use voice while navigation stays active.
5. Azure revoicing, barge-in and navigation guidance share controlled audio arbitration, with no self-barge or overlapping voices.
6. Build is installable on a physical iPhone with passing device evidence, an honest demo, and release notes.

The **minimum** December 4 deliverable is an installable signed build / TestFlight beta where eligible. A **public App Store release cannot be guaranteed** on this date because it depends on Apple review. Do not present CarPlay, real vehicle controls, or unfinished optional integrations as released.

## Evidence-based baseline (reviewed 2026-10-26)

- Code already includes functional Swift core pieces for session lifecycle, tool validation/guards, simulated vehicle, truthfulness gating, Gemini codec/transport/fixtures, Azure speech and agent orchestration; `specs/work.json` records core PASS and latest `specs/STATUS.md` reports CI green.
- The app in `App/NovaDrive/` is still a **four-tab device engineering test app**; `App/NovaDrive/NovaDriveApp.swift` has no integrated main driving UI.
- `NovaNavAmap`, `NovaPlatform`, `NovaWakeIflytek` contain placeholders. Real audio adapter T-021 and app wiring T-025 are marked BLOCKED_EXTERNAL.
- Device echo test T-001 on **iPhone 17 / iOS 26.6.1** (Oct 25) failed: **6/10 then 8/10** silent trials closed, below ≥9/10. Fix this before promising natural barge-in.
- Six Gemini protocol fixtures have been captured using **scripted text**, not spoken live audio. `goAway` remained unobserved.
- The repo's `specs/work.json` currently registers tasks only through **T-026**. Before scheduling agents for M2–M5, append bounded, dependency-tracked entries and require independent review + deterministic evidence as `AGENTS.md` demands.

## Weekly milestone map

| Week | Deadline | GitHub tracker | Physical proof to close |
|---|---|---|---|
| W1 — Unblock audio and compose app shell | Sun Nov 1 | [#8](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/8) | AEC ≥9/10 on two fresh runs; live audio 10 turns; Amap feasibility probed |
| W2 — E1 live voice and truthful tools | Sun Nov 8 | [#9](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/9) | W1–W4 PASS on iPhone; ≥20 live turns; median first audio ≤3 s; stop ≤300 ms |
| W3 — E2 navigation | Sun Nov 15 | [#10](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/10) | Real Amap POI→route→NAVIGATING and W8 cancel, 5 full cases |
| W4 — E3 integrated drive | Sun Nov 22 | [#11](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/11) | Guidance vs reply W5 no overlap (10 collision cases); 5 route+voice scenarios |
| W5 — Release candidate hardening | Sun Nov 29 | [#12](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/12) | Two 30-min controlled regressions, release candidate, no P0/P1, permissions and privacy PASS |
| W6 — Product delivery | Fri Dec 4 | [#13](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/13) | Signed/installable build, final W1–W8 device test record, real video, docs, release tag |

Each linked issue has work packets, exact expected evidence, dependencies, and acceptance conditions. **Do not close a weekly issue based solely on unit tests, speculative UI screenshots, or mock responses.**

## Critical path

`T-001 → G0 (AEC decision) → T-021 (audio) → T-025 (integrated app) → T-026 (device E1) → T-040..048 (navigation) → T-050..054 (guidance) → RC → release`

Run the Amap T-002 spike **concurrently with W1** so an SDK/key issue is discovered weeks before the navigation milestone.

### Mandatory decisions by 2026-10-28

1. **AEC:** Apple VP passes the device gate, or commit to the WebRTC AEC3 fallback. Never tune the gate by simply hiding genuine user barge-in.
2. **Distribution:** confirm Apple Developer Program and code signing / App Store Connect access now. Existing `.github/workflows/ipa.yml` creates an **unsigned** IPA; unsigned artifact ≠ general-user distribution.
3. **Deployment:** iOS 18 is the existing `App/project.yml` minimum; record it as accepted or intentionally modify it.
4. **Providers and credentials:** test Gemini, Azure and Amap keys on the physical device; never commit them.

### Scope triage when behind

- **Always P0:** audio reliability, actual live conversation, verified actions, destination search/route start, safe cancellation, guidance/voice arbitration, usable permissions/onboarding, release signing.
- **P1 if time:** context/ambiguity, comfort scenarios, live ETA/weather where a real source is available, bundled music, foreground wake phrase if licensed and device verified.
- **After Dec 4 unless earlier proof exists:** CarPlay, phone calls, camera vision, MusicKit named songs, broad Android feature parity, actual vehicle hardware controls, unrestricted background listening.

If AEC is still below threshold at W2, the full voice MVP is **BLOCKED**, not PASS. Continue independent navigation and UI implementation, but report the December deadline as at risk. If public App Store availability is the real goal, submit earlier and treat review as an external dependency.

## Weekly review ritual

Every **Friday**:
1. Run CI, rerun critical unit/contract and device tests, and retain build SHA, physical device, iOS version, network and raw outcomes.
2. Update `specs/STATUS.md` and `specs/work.json`: `PASS`, `REWORK`, `BLOCKED`, or `NOT_VERIFIED`. A human device task can never be silently promoted by an AI-generated test.
3. Close that week's GitHub tracking issue **only** when exit criteria pass. Move unfinished **P0** work explicitly to next week and cut a P1/P2 feature of comparable effort.
4. Use the project's bounded Executor → gates → independent read-only Reviewer process. Prevent indefinite automation loops.

## Release go / no-go

**GO only if:** voice tool truthfulness and physical audio gates pass; navigation actually starts and cancels; no false vehicle/hardware claim; no P0 or P1 bug; signing and install confirmed; no secrets/PII in artifact/logs; CI green; actual-device evidence retained.

**NO-GO:** any device-only acceptance still NOT_VERIFIED or fails for a must-have feature. A polished showcase video or a passing simulator does not override this gate.
