# Nova Drive iOS — demo recording specification

**Spec ID:** IOS-DEMO-001  
**Version:** 1.0 — 2026-10-26  
**Status:** READY TO EXECUTE for engineering demo; PRODUCT DEMO BLOCKED until device acceptance  
**Target:** Nova Drive (小诺), native iPhone app; see [product-spec.md](product-spec.md), [migration-plan.md](migration-plan.md), and [STATUS.md](STATUS.md).

## 1. Goal and non-goals

Record an honest, reproducible **video showing the iOS app running on an actual iPhone**, with visible proof of each claimed behavior. The recording must distinguish functioning product paths, isolated engineering experiments, simulated actions, and planned features.

Deliver two separately labeled outputs:

- **A — Engineering proof (recordable now):** 60–120 s edited overview of the current test app. Demonstrate visible vehicle tool results, microphone/echo test UI, and Gemini Live fixture recording. Disclose that voice-agent conversation and navigation are **not yet verified end to end on iOS**.
- **B — Product showcase (after readiness gates):** 2–3 min live foreground iPhone demo of natural Mandarin voice interaction, real model calls, verified tool results, interruption, and—once implemented—Amap navigation. Record missing features separately when milestones land; **do not stage a full product demo by combining unrelated unit-test screens**.

**Not requested / not in scope:** building an in-app video recorder; fabricating interactions; claiming CarPlay, real climate control, or Baidu as the active provider; editing the application’s behavior just to make a deceptive recording.

## 2. Ground truth and readiness

As checked against the repository on 2026-10-26:

- The existing executable is an iOS 18+ SwiftUI **device test app**, defined by **App/project.yml**, bundle ID **com.asapacsin.novadrive**, display name **Nova Drive**, with four tabs: **车辆**, **音频测试**, **录制**, **设置** ([NovaDriveApp.swift](../App/NovaDrive/NovaDriveApp.swift)).
- The **车辆** tab invokes climate/seat/window **simulated tool handlers** by tapping buttons; that does **not** prove speech-to-speech execution.
- **音频测试** runs an on-device echo/AEC spike. The 2026-10-25 physical iPhone 17 run **failed** the ≥9/10 silence criterion (6/10, then 8/10 with Apple voice processing at max speaker volume). Do not mark microphone barge-in reliable; see [STATUS.md](STATUS.md) T-001.
- **录制** means **Gemini protocol fixture recording** to Documents/fixtures, using scripted text (no spoken utterance); **not a camera/screen capture tool** ([RecorderView.swift](../App/NovaDrive/RecorderView.swift)). Six of seven fixtures were obtained on-device; goAway is still unverified. This is T-003 evidence, **not** a real-time voice demo.
- The intended **active** model path is end-to-end **Gemini Live real-time voice interaction** with provider-neutral tools; configured assistant voice uses **Azure TTS** on output. Describe this faithfully: do **not** call it a traditional ASR → LLM → TTS pipeline, and do **not** claim the dormant Baidu path is the live iOS backend. Azure revoicing is an output-stage customization.
- Current iOS main app is **not** the complete navigation/voice product. The full M1 device acceptance and M3/M4 navigation/voice-guidance acceptance remain distinct proof gates. See [implementation-plan.md](implementation-plan.md).

| Demo level | Allowed evidence / claim | Required gate |
|---|---|---|
| E0: engineering | Test app, simulated vehicle tool outcomes, echo spike, Gemini fixture statuses | Installed app runs on iPhone; label every scenario and its actual result |
| E1: voice MVP | Spoken request → live realtime session → validated tool → result read-back → spoken answer; interruption | M1 W1–W4 pass at device (D) level; T-026 completed, AEC decision recorded |
| E2: navigation | Live POI search → candidate selection → route selection → Amap navigation actually starts | M3 W8 simulator evidence and physical device run of J2 |
| E3: integrated drive | In-navigation questions, guidance arbitration, no overlapping voices | M4 W5 and F-14 D evidence |
| E4: optional | Wake word, background behavior, music, CarPlay | Relevant M5/M6/M7 acceptance and permissions, each specifically named |

**Block a product claim when its gate is NOT_VERIFIED, FAIL, or still only U/S.** Any fallback or planned scenario must be explicitly captioned as a simulation/preview.

## 3. Recording method — prefer actual iPhone, no Mac required

### 3.1 Preparation

1. Install the intended build on the iPhone and launch **Nova Drive**. Keep the app in the foreground. Note **device, iOS version, build commit SHA, build version, date, network type, provider, and whether each feature uses a mock** in the evidence sheet.
2. Verify required permissions, service reachability and consent **before** recording. Keys reside in Keychain; never show the entry, logs, account pages, exact addresses, contact names or private credentials.
3. Enable Do Not Disturb/Focus to prevent notifications; ensure sufficient charge/storage; use a quiet room and stable network. Use a demonstration location/route rather than personal addresses.
4. **Preflight audio:** record a 10–15 s sample. Listen to it in Photos. Confirm narrator/driver **and** assistant audio are audible, dialogue and UI are synchronized, and starting the screen recording did not change the app microphone/audio-session behavior.
5. If the iOS screen recorder captures only one side, or alters live mic/echo behavior, **switch to a second-phone camera or external microphone recording the physical iPhone and the driver at the same time**. Do not splice a model response from another attempt and present it as a single live interaction.

### 3.2 On-device video capture (default)

1. On iPhone, swipe down from top-right to open **Control Center**.
2. If absent, long-press the background → **Add a Control** → **Screen Recording**.
3. Touch and hold **Screen Recording**, select **Microphone On**, then **Start Recording** (3-second countdown). Return to Nova Drive.
4. Perform one clearly labeled scene at a time, allowing UI and sound to settle. Avoid filming passwords or keys.
5. Tap the red recording indicator / timer and **Stop**. In **Photos → Collections → Media Types → Screen Recordings**, open the file and check sound and visuals.
6. Trim dead time **without rearranging cause and effect**. Retain an unedited source take as evidence.

Apple: [screen recording, including microphone](https://support.apple.com/en-us/102653). A connected Mac can alternatively capture the iPhone via **QuickTime Player → File → New Movie Recording → Camera: iPhone**: [Apple instructions](https://support.apple.com/en-by/guide/quicktime-player/qtp356b55534/mac). A Mac is **optional**, not a prerequisite to capture.

**Audio caveat:** screen-recording microphone availability does not guarantee two-way live voice-app audio. The preflight is a hard gate, especially after the observed AEC failure.

## 4. Script A — engineering evidence, available now

Record individual takes (do not wait for the long goAway experiment during the video); edit to a **60–120 s** engineering overview.

| Shot | Screen / action | Visible result / spoken narration | Pass condition |
|---|---|---|---|
| A0, 0–8 s | Title card + open Nova Drive **车辆** tab | “Nova Drive iOS — engineering prototype, physical iPhone” | Version/date visible in caption; no full-product claims |
| A1, ~8–30 s | Tap **空调开**, **温度 -1**, **开车窗** | Each button yields a result row; disclose **simulated vehicle** | Appropriate result row for each action, no false success |
| A2, ~30–65 s | Open **音频测试**, show **Apple 回声消除** and execute **开始测试** on a safe controlled device | Show raw measured report, **including FAIL** if repeat reproduces it | Real device report captured; do not edit a FAIL into PASS |
| A3, ~65–100 s | Open **录制**, run **只录前 6 段** only if credentials/network are ready; show statuses | Explain “scripted Gemini Live contract fixtures; no spoken mic interaction” | Actual 6 scenario statuses shown accurately; failures left visible |
| A4, last ~10 s | End card | “Next: integrated live voice session, truthful action execution, navigation” | Clear distinction between shipped, tested, and planned |

For an external-facing short clip, shots A2–A3 may be summarized with one honest screenshot each, but keep the original complete takes for internal verification. Never open **设置** while keys could be exposed.

## 5. Script B — actual product showcase, release-gated

**Run only segments whose device-level gates passed.** Capture the entire interaction in one continuous iPhone session per segment. Prompts are Mandarin because the port’s current product decision is Mandarin-first.

| Shot | Spoken input / setup | Must be visible or audible | Dependency |
|---|---|---|---|
| B1 — real-time voice | Tap-to-talk (if wake word not ready), say **“小诺，打开空调。”** | LISTENING → user speech → processing → exactly one tool result **ok=true** → simulated AC state changes → truthful spoken answer | M1 W1, D |
| B2 — natural interruption | While 小诺 is speaking, begin **“等一下，把温度调低一点。”** | Previous speech stops; superseded audio does not resume; new intent runs exactly once | M1 W2, D; actual measured AEC/barge-in |
| B3 — safe failure | Trigger a rehearsed, user-visible unsupported command such as **“打开天窗。”** | Honest unavailable/unsupported response; **no** window mutation or fictional success | F-09/F-11 integrated D |
| B4 — navigation | **“导航去珠海站。”** → select the second real candidate → select the offered route → start | Actual Amap candidate list, route(s), then **NAVIGATING** state and displayed route, not merely “已开始导航” speech | M3 F-15/F-16, D |
| B5 — drive context | During **Amap emulator navigation** (explicitly labeled **simulated movement**), say **“还有多久到？”** | Route state remains intact; answer based on real SDK data | M3/M4, D |
| B6 — arbitration | Interrupt near a navigation guidance event | Navigation instruction and assistant reply do not overlap or repeat | M4 W5, D |

**Do not substitute** a Gemini fixture text turn for B1, a direct UI button press for a spoken tool call, a fake map for Amap SDK route execution, or an animated route for a real moving vehicle. CarPlay and wake word are separate milestones and not required for B1–B6.

## 6. Acceptance criteria

| ID | Verification | Required |
|---|---|---|
| REC-001 | Filename and evidence sheet identify physical device, iOS, build SHA, timestamp, and E0/E1/E2/E3 capability level | PASS |
| REC-002 | Original uncut footage is retained; final editing never changes event order or hides material failure | PASS |
| REC-003 | Video reveals no keys, tokens, contact details, private addresses or unintended notification content | PASS |
| REC-004 | Playback review confirms readable UI, sufficient sound, lips/voice/assistant response synchrony when relevant | PASS |
| REC-005 | Every claimed model/tool/navigation step is supported by matching on-device action/result evidence | PASS |
| REC-006 | **Simulated** cabin control and **simulated** navigation movement are labeled; no claim of actual car hardware control | PASS |
| REC-007 | B1/B2/B4/B6 omitted or stamped NOT_VERIFIED until corresponding D-level gates pass | PASS |
| REC-008 | No product-demo release while echo/voice test gate G0 blocks M1; failures reported honestly | PASS |
| REC-009 | Final export plays completely on a different player/device; source and edit versions independently accessible | PASS |

**Proposed video deliverables:** original portrait iPhone recording (unaltered; native resolution), edited MP4 H.264/AAC, and one Markdown evidence sheet. Target **≥720p at ~30 fps** where capture supports it. A 1920×1080 landscape cut may center/crop/pad the portrait screen without inventing pixels or hiding status. Keep product-cut length **2–3 minutes**, engineering-cut length **60–120 seconds**. Do not commit large video binaries to Git history; attach via a release or external artifact location, with the link and checksum in evidence.

Suggested names:
- ios_novadrive_E0_engineering_YYYYMMDD_take01.mov
- ios_novadrive_E0_engineering_YYYYMMDD_final.mp4
- ios_novadrive_E1_product_YYYYMMDD_final.mp4
- ios_novadrive_E2_navigation_YYYYMMDD_final.mp4
- specs/demo/evidence/YYYYMMDD.md (small metadata/result file, once created)

## 7. Required evidence sheet

For each demo record:

- **Build:** commit SHA, app version, binary origin (local Xcode / CI IPA), code-signing/install method
- **Environment:** iPhone model and iOS version, connection type, microphone / output route, noise conditions
- **Mode:** E0/E1/E2/E3; real provider vs recorded fixture vs simulated tool; speaker/mic capture method
- **Scenarios:** A1/A2/A3 or B1–B6, with outcome **PASS / FAIL / NOT_VERIFIED / BLOCKED** and any matching W/F/T IDs
- **Measurements:** AEC silent trials, barge-in delay, first-audio latency only when directly measured; do not reuse Android numbers as iOS results
- **Artifacts:** raw video reference, edited video reference, SHA-256 checksums, audio spot-check, redaction result
- **Limitations:** failures, skipped scenes, device-repro blockers and next owner action

Before publishing a user-facing demo, the owner verifies footage and signs off on the capability labels. If AEC remains unreliable, prioritize **making the live session reliable** over polishing camera angles or editing.

## 8. Completion workflow for agents (/goal)

**Goal:** Produce the strongest *truthful* available iOS demo with reproducible evidence, not merely “a video file exists.”

- [ ] Read this spec and latest [STATUS.md](STATUS.md); identify the highest gate with device PASS.
- [ ] Build/install or use an already verified iPhone build. Never assume simulator-only tests establish device behavior.
- [ ] Run REC-001–004 preparation and a 10–15 s audio capture preflight.
- [ ] Record scenes **only** up to the highest verified gate; use Script A when B is blocked.
- [ ] Inspect raw takes for claims, result read-back, audio, secrets, and truthful simulation labels.
- [ ] Edit without changing causal order; export a playable file and save raw source separately.
- [ ] Write evidence sheet, mark REC-001–009 and any W1–W8 outcomes with proof references.
- [ ] Return **PASS** only when required checks hold; **REWORK** for recoverable capture/edit errors; **BLOCKED** for missing feature/device/key/permission; **NOT_VERIFIED** when evidence is insufficient. Stop retrying at the existing bounded workflow limits.
- [ ] Finish with final file locations and a concise statement of **shown**, **not yet shown**, and **blocking issue**.

This document **specifies** recording. It does not claim footage was captured or that unfinished iOS features passed device tests.
