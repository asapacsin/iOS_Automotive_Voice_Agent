# Nova Drive iOS — November 27 product completion, December 4 delivery

**Plan version:** 2026-10-26 (revised: 7-day contingency requirement)  
**Timezone:** Asia/Macau (UTC+08:00). Every date below is a local date.  
**Hard internal product-complete deadline:** **Friday, 2026-11-27, 23:59 Asia/Macau** — seven full calendar days ahead of delivery.
**External delivery deadline:** **Friday, 2026-12-04**. The entire Nov 28–Dec 4 interval is reserved contingency, **not a planned implementation phase**.
**Feature freeze:** **Friday, 2026-11-20** (core functionality merged and demonstrated).  
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

The **November 27 completed-product deliverable** is a **signed, physically installable and tested** iPhone MVP / TestFlight beta where eligible, plus device acceptance evidence, a real demo, a release tag and docs. Do not defer these to December. A **public App Store release cannot be guaranteed** on this date because it depends on Apple review. Do not present CarPlay, real vehicle controls, or unfinished optional integrations as released.

## Evidence-based baseline (reviewed 2026-10-26)

- Code already includes functional Swift core pieces for session lifecycle, tool validation/guards, simulated vehicle, truthfulness gating, Gemini codec/transport/fixtures, Azure speech and agent orchestration; `specs/work.json` records core PASS and latest `specs/STATUS.md` reports CI green.
- The app in `App/NovaDrive/` is still a **four-tab device engineering test app**; `App/NovaDrive/NovaDriveApp.swift` has no integrated main driving UI.
- `NovaNavAmap`, `NovaPlatform`, `NovaWakeIflytek` contain placeholders. Real audio adapter T-021 and app wiring T-025 are marked BLOCKED_EXTERNAL.
- Device echo test T-001 on **iPhone 17 / iOS 26.6.1** (Oct 25) failed: **6/10 then 8/10** silent trials closed, below ≥9/10. Fix this before promising natural barge-in.
- Six Gemini protocol fixtures have been captured using **scripted text**, not spoken live audio. `goAway` remained unobserved.
- The repo's `specs/work.json` currently registers tasks only through **T-026**. Before scheduling agents for M2–M5, append bounded, dependency-tracked entries and require independent review + deterministic evidence as `AGENTS.md` demands.

## Weekly milestone map (internal completion Nov 27)

| Week | Window / gate | GitHub tracker | Physical proof to close |
|---|---|---|---|
| W1 — Unblock audio and app shell | Oct 26–Nov 1 | [#8](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/8) | AEC ≥9/10 twice; 10 live turns; Amap feasibility; Apple signing account confirmed |
| W2 — E1 live voice & truthful tools | Nov 2–8 | [#9](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/9) | W1–W4 physical-device cases; 20 turns, latency/barge-in evidence; first **signed-install smoke test** |
| W3 — E2 navigation | Nov 9–15 | [#10](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/10) | POI → route → NAVIGATING and W8 cancel; 5 cases |
| W4 — E3 integrated drive + feature freeze | Nov 16–22; **freeze Nov 20** | [#11](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/11) | Guiding vs assistant W5 no overlap, 5 integrated route+voice cases; P0 code feature-complete Nov 20; Nov 21–22 are bug-fix only |
| W5 — **Actual product delivery and acceptance** | Nov 23–**27** | [#12](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/12) | W1–W8 scoped acceptance, two 30-minute device runs, zero release-blocking bugs, **signed installable build + install verification**, tag, real demo, docs |
| W6 — **Unused unless a new blocker occurs** | Nov 28–Dec 4 | [#13](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/13) | Seven-day **contingency only**, not a development or initial delivery milestone; maintain freeze |

A milestone can be closed only when its evidence is attached. If a mandatory device row is NOT_VERIFIED or FAIL, the actual completion milestone (#12) is NO-GO.

### Calendar and slack rules

- **Nov 20:** The must-have voice+tool+navigation+guidance functionality is integrated and running on the target iPhone. **No new feature work after this date.**
- **Nov 21–22:** Stabilize integrated release candidate; fix only acceptance blockers.
- **Nov 23–27:** Dedicated end-to-end physical validation, regression, security checks, signing, installation, honest demo, release tag and documentation. **This is still scheduled work, not the seven-day buffer.**
- **Nov 27 23:59:** Declare product-complete only if the build installs and the required tests pass on a physical device. Record the verdict in STATUS.md.
- **Nov 28–Dec 4:** Leave completely empty in the baseline work plan. If unexpected P0/P1 issues appear, use this reserve for targeted repairs and revalidation, not new feature requests. The December 4 delivery is external, but **missing Nov 27 is still reported as a missed internal deadline**.
- **Public App Store approval** is an external uncertainty. An accepted TestFlight beta / a registered-device signed build is an achievable engineering outcome, while public approval cannot be assumed.

Each linked GitHub issue includes detailed tasks and acceptance criteria. These are tracking issues, not native GitHub milestone objects.

## Critical path

`T-001 → G0 (AEC decision) → T-021 (audio) → T-025 (integrated app) → T-026 (device E1) → T-040..048 (navigation) → T-050..054 (guidance) → NOV 20 FEATURE FREEZE → NOV 27 SIGNED DEVICE-ACCEPTED MVP`

Run the Amap T-002 spike **concurrently with W1** so an SDK/key issue is discovered weeks before the navigation milestone.

### Mandatory decisions by 2026-10-28

1. **AEC:** Apple VP passes the device gate, or commit to the WebRTC AEC3 fallback. Never tune the gate by simply hiding genuine user barge-in.
2. **Distribution:** by Nov 1 confirm Apple Developer Program and code signing / App Store Connect access; by Nov 8 complete a first signed install and cold launch on a device. Existing `.github/workflows/ipa.yml` creates an **unsigned** IPA; unsigned artifact ≠ installable production build.
3. **Deployment:** iOS 18 is the existing `App/project.yml` minimum; record it as accepted or intentionally modify it.
4. **Providers and credentials:** test Gemini, Azure and Amap keys on the physical device; never commit them.

### Scope triage when behind (protect the earlier deadline)

- **Always P0:** audio reliability, actual live conversation, verified actions, destination search/route start, safe cancellation, guidance/voice arbitration, usable permissions/onboarding, release signing.
- **P1 if time:** context/ambiguity, comfort scenarios, live ETA/weather where a real source is available, bundled music, foreground wake phrase if licensed and device verified.
- **Defer past the Nov 27 internal completion deadline unless earlier proof exists:** CarPlay, phone calls, camera vision, MusicKit named songs, broad Android feature parity, actual vehicle hardware controls, unrestricted background listening.

If AEC is still below threshold at W2, the full voice MVP is **BLOCKED**, not PASS. Continue independent navigation and UI implementation, but report **Nov 27 completion at risk** immediately. If public App Store availability is the real goal, submit earlier and treat review as an external dependency.

**Risk response:** If the scope is too large, remove extras, **not validation days**. Advanced context, weather, bundled music, wake-word SDK, phone, vision and CarPlay must not displace the essential voice+tool+route+guidance loop. W5 is protected for acceptance and shipping; W6 is protected contingency.

## Weekly review ritual

Every **Friday**:
1. Run CI, rerun critical unit/contract and device tests, and retain build SHA, physical device, iOS version, network and raw outcomes.
2. Update `specs/STATUS.md` and `specs/work.json`: `PASS`, `REWORK`, `BLOCKED`, or `NOT_VERIFIED`. A human device task can never be silently promoted by an AI-generated test.
3. Close that week's GitHub tracking issue **only** when exit criteria pass. Move unfinished **P0** work explicitly to next week and cut a P1/P2 feature of comparable effort.
4. Use the project's bounded Executor → gates → independent read-only Reviewer process. Prevent indefinite automation loops.

## Release go / no-go

**GO on Nov 27 only if:** voice tool truthfulness and physical audio gates pass; navigation actually starts and cancels; no false vehicle/hardware claim; no P0 or P1 bug; signing and install confirmed; no secrets/PII in artifact/logs; CI green; actual-device evidence retained.

**NO-GO on Nov 27:** any device-only acceptance still NOT_VERIFIED or fails for a must-have feature. A polished showcase video or a passing simulator does not override this gate.


## Nov 27 readiness evidence packet

Before closing [#12](https://github.com/asapacsin/iOS_Automotive_Voice_Agent/issues/12), attach or link these dated, reproducible assets:

1. Signed artifact/install method, bundle identifier, marketing/build version, Git commit/tag and target device/OS.
2. Clean-install and cold-launch smoke test video or log on a physical iPhone.
3. All must-have scenario results (W1–W5, W7–W8; W6 only if its ambiguity feature is included) with measured AEC, latency, barge-in and guidance outcomes. A failure/NOT_VERIFIED on an essential scenario blocks completion.
4. CI summary (Xcode, Swift tests, contract fixture replay, lint, secrets/imports) and no P0/P1 defects.
5. 2–3 minute unedited-source-backed actual iPhone product demo, truthful labeling of simulated capabilities.
6. Install instructions, setup/consent/permission steps, supported scope, limitations, known issues and release notes.

**A green CI build alone is insufficient. A recorded video alone is insufficient. The signed artifact must actually work on the intended phone before the seven-day buffer starts.**
