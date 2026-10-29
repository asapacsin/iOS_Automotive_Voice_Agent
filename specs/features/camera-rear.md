# F-20b Rear view in the camera window (前方 / 后方 switch)

**Status:** APPROVED (owner request 2026-10-27: "the camera should also show the rear, not just the forward one").
Defaults below are decided; OQ-CAM-3/4 stay open with the recommended answer used until the owner says otherwise.
**Extends:** [F-20a Camera button, live preview window](camera-view.md). Everything in F-20a still holds unless
this file changes it.
**Depends on:** F-20a (T-071a–d), F-09 (tool dispatch), contracts/api-contracts.md

## 1. Purpose
With the phone mounted facing the road, the back lens sees **前方** (ahead of the car) and the front (selfie)
lens sees **后方**: the cabin and, through the rear window, behind the car. The driver can switch the window
between the two and ask 小诺 about either.

## 2. User-facing behaviour
- The camera window from F-20a gets a **switch button** (SF Symbol `arrow.triangle.2.circlepath.camera`) next to
  问一下, and a small label in the window's top-left corner: **前方** or **后方**.
- Tap the switch → the preview changes to the other lens within 1 s; the label follows. The window size, place
  and 问一下 stay the same.
- The window opens on the lens used last in this app session; the first open of a session uses **前方**.
- Voice picks the lens from the question:
  - 「后面是什么？」「后面有车吗？」「车里有人吗？」「后排……」 → **后方**;
  - 「前面是什么？」「路上……」 → **前方**;
  - a question that names neither (「画面里有什么？」) → the lens the window shows now.
  If the named lens is not the one showing, the window switches first (the label changes), then takes the picture.
- 问一下 asks about the lens that is showing.
- The answer says which side she looked at when it was a switch: 「后面……」 / 「前面……」 (the tool result
  carries `camera`; the model does not guess it).

## 3. Preconditions
Same as F-20a §3. Both lenses use the one camera permission. A device without a front lens (none among
supported iPhones, but simulators have none) shows the switch disabled.

## 4. Inputs and outputs
- `describe_camera_view(question, camera?)`: new optional argument `camera`, enum `"front_view"` (前方, back lens)
  | `"rear_view"` (后方, selfie lens). Omitted → the lens chosen by §2 from the question words, else the one showing.
  The names describe what is seen, not the hardware lens, so the model never has to know which lens is which.
- Result adds `camera: "front_view" | "rear_view"`: `{ok:true, answer, seen_at_ms, camera}`.
- Frame rules are unchanged (F-20a §4): one JPEG ≤ 1024 px, quality 0.7, not older than 1 s. The selfie
  frame is **not mirrored** (it is sent as the lens sees it), so left and right in her answer are true.

## 5. State transitions
F-20a's machine gains a `lens` value (`frontView` | `rearView`) and one transition:
`previewing → switching (reconfigure session input) → previewing`. A question that arrives during `switching`
waits for it (≤ 1 s) and then captures; a switch requested while `asking` waits until the frame is taken
(the in-flight request is not cancelled by a switch).

## 6. Events and triggers
F-20a's events, plus: switch tap; `describe_camera_view` with a `camera` (or question words) naming the
other lens.

## 7. Dependencies and external services
- `CameraSession` (NovaPlatform/Camera) swaps its `AVCaptureDeviceInput` between
  `.builtInWideAngleCamera` `.back` and `.front` inside `beginConfiguration/commitConfiguration`; one
  `AVCaptureSession`, one lens at a time (no `AVCaptureMultiCamSession`, see OQ-CAM-3).
- The preview layer for `.front` turns off automatic mirroring for the still (`AVCaptureConnection
  .isVideoMirrored = false` on the photo output); the on-screen preview may stay mirrored like the system
  camera (OQ-CAM-4).
- The lens choice from words is pure Swift in NovaTools/Vision (`CameraLensChooser`), tested with fakes.
- Vision backend and reply path are unchanged (F-20a §7).

## 8. Error handling and recovery
| Case | Result / what she says |
|---|---|
| Selfie lens missing or fails to start | `CAMERA_UNAVAILABLE` for 后方 only: 「后面的摄像头现在用不了。」; 前方 keeps working |
| Switch fails mid-preview | stays on the old lens, label unchanged, logged as `CAMERA_SWITCH_FAILED` (log only) |
| `camera` argument not in the enum | `INVALID_ARGUMENT` (dispatcher schema check) |
All F-20a §8 rows still apply. Codes only in logs; images and question text are never logged (I-8).

## 9. Concurrency, cancellation, timeouts
Switch deadline 1 s; one switch at a time (a second tap while switching is ignored). Closing the window during
a switch stops the session; nothing is captured. F-20a §9 otherwise.

## 10. Acceptance criteria (iOS)
| # | Criterion | Level |
|---|---|---|
| 1 | Tap switch → preview shows the other lens within 1 s, label 前方/后方 follows | D |
| 2 | 「后面是什么？」 with 前方 showing → window switches to 后方, exactly one frame from the selfie lens is sent, answer matches the scene | D (3 scenes) |
| 3 | `CameraLensChooser`: 后面/后排/车里 → rear_view; 前面/路上 → front_view; neither → current; both named → current | unit |
| 4 | Result carries `camera`; a switch never cancels the in-flight question; a question during switching waits then captures | unit (fake session) |
| 5 | Selfie frame sent unmirrored (text in the scene reads correctly in the uploaded JPEG) | D |
| 6 | Closing the window stops the session whichever lens is active; green camera dot goes away | D |
| 7 | Rear lens failure → 「后面的摄像头现在用不了。」, 前方 still answers | unit |

## 11. Implementation constraints
- Capture code only in NovaPlatform/Camera; lens choice and result shape pure in NovaTools/Vision (F-20a §13).
- The tool catalog change (`camera` property, description mentions 后面) is a catalog edit with its golden test
  updated; the property stays optional so older prompts keep working.
- No image is sent at a switch; only at a question (F-20 row 2 still holds).

## Open questions
- OQ-CAM-3 (default: **one lens at a time with a switch**): should the window show both lenses at once
  (picture-in-picture via `AVCaptureMultiCamSession`)? Costs more battery and heat; MultiCam is supported on
  current iPhones. Recommendation: switch only.
- OQ-CAM-4 (default: **preview mirrored like the system camera, still sent unmirrored**): should the 后方
  preview be mirrored on screen?

## Tasks (implementation-plan.md M6, specs/work.json)
| ID | Task | Verification |
|---|---|---|
| T-071e | `CameraLensChooser` + `camera` argument/result in `CameraQuestionHandler`; catalog property | unit |
| T-071f | `CameraSession` lens switch (`.back` ↔ `.front`, unmirrored still, 1 s deadline) | build, D |
| T-071g | Window switch button, 前方/后方 label, voice-driven switch before capture | S, D |
