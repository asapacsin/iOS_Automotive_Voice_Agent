# F-20a Camera button, live preview window and "what is there?" questions

**Status:** PROPOSED (iOS only, 2026-10-26). Extends [F-20 Camera vision questions](vision.md); the
`describe_camera_view` tool, `CameraFrameSource` and `VisionPort` ports already exist (NovaPorts).
**Depends on:** F-20, F-25 (drive screen), F-09 (tool dispatch), F-07 (reply voice), contracts/api-contracts.md

## 1. Purpose
Let the driver (or a passenger) open a small live view of the camera on the drive screen and ask
小诺 what is in it, by voice or by tapping, and get a spoken answer based only on that picture.

## 2. User-facing behaviour
- A **camera icon** (SF Symbol `camera.fill`) sits on the drive screen header next to the status chip.
- Tap it → a **small floating window** (picture-in-picture style, about 40 % of the screen width,
  4:3, rounded corners, top-right below the header) shows the **back (world-facing) camera** live.
  "Front of the camera" means what the lens faces, i.e. the road ahead when the phone is mounted.
  The window has a close button (×) and an **问一下** button; it can be dragged to another corner.
- Ask by voice while the window is open: 「前面是什么？」「画面里有几个人？」「这是什么车？」 → the chip shows
  思考中, a short **看画面中…** label shows on the window, then 小诺 answers in one or two sentences, and the
  answer also shows as her bubble.
- Tap **问一下** → same as asking 「画面里有什么？」.
- Asking a camera question while the window is closed opens it, takes the picture and answers
  (the window stays open until closed).
- Tap the icon again or × → the window closes and the camera stops (green camera dot goes away).

## 3. Preconditions
- Camera permission (`NSCameraUsageDescription`: 「Nova Drive 需要用摄像头回答你关于画面的问题。」). First tap
  asks for it; if denied, the icon shows a slash and a tap explains how to allow it in Settings.
- A vision backend key: **Gemini key (already stored)** is the default; Qianfan key optional (OQ below).
- A live session is not required for the tap path; the voice path needs the running session.

## 4. Inputs and outputs
- In: the driver's question (voice → `describe_camera_view(question)`, or tap → fixed question
  「画面里有什么？请简短描述。」), one still frame from the open preview.
- Frame: one JPEG, longest side ≤ 1024 px, quality 0.7, taken at the moment of the question
  (not a frame older than 1 s).
- Out (tool result to the model): `{ok:true, answer:"…", seen_at_ms}` or `ok:false` with a code and
  `next` sentence; the model speaks only the answer (tool description: "只按返回的 answer 答").

## 5. State transitions
`closed → opening (permission/camera start) → previewing → asking (frame captured, request in flight)
→ previewing` ; any → `closed` on ×, icon tap, app background, or session stop. Only one question in
flight; a new question cancels the old request (its answer is dropped, never spoken).

## 6. Events and triggers
Icon tap, × tap, 问一下 tap, `describe_camera_view` tool call, app scene going to background.

## 7. Dependencies and external services
- `AVCaptureSession` (`.builtInWideAngleCamera`, `.back`) feeding an `AVCaptureVideoPreviewLayer`
  and an `AVCapturePhotoOutput`/video-data output for the still — adapter in NovaPlatform (Camera), I-9.
- Vision backend behind `VisionPort`:
  - Default **Gemini** `generateContent` (model `gemini-flash-latest`, image + question, system text
    「只根据图片回答，看不清就说看不清，不要猜。用一两句中文口语回答。」), same Keychain key as Live.
  - Optional **Qianfan** (F-20 Android parity) when a Qianfan key is saved.
- Answer voiced through the normal reply path (Gemini Live → revoicer → Azure); the tap path sends the
  answer to the model as text so she speaks it, or speaks it directly through the revoicer when no
  session runs.

## 8. Error handling and recovery
| Case | Result / what she says |
|---|---|
| No permission | `CAMERA_PERMISSION_DENIED`: 「摄像头没有权限，请在设置里允许。」 |
| Camera busy / start failed | `CAMERA_UNAVAILABLE`: 「摄像头现在用不了。」 |
| No vision key | `NOT_CONFIGURED` (VisionAnswer.notConfigured): 「看图功能还没有配置。」 |
| Auth failure (401/403) | `AUTH_FAILED`: 「看图服务的密钥无效。」 |
| Timeout (8 s) / network | `VISION_FAILED`: 「刚才没看清楚，再问我一次吧。」 |
| Model says it cannot tell | spoken as is; never guessed (I-1). |
Codes only in logs; the image and the question text are never logged (I-8).

## 9. Concurrency, cancellation, timeouts
Request deadline 8 s; one in flight; barge-in cancels speaking the answer as for any reply (F-08);
closing the window cancels an in-flight request. Camera stops within 1 s of closing.

## 10. Acceptance criteria (iOS)
- Tapping the camera icon opens the floating window with a live back-camera preview within 1.5 s (D).
- With the window open, 「前面是什么？」 produces exactly one `describe_camera_view` call, one image
  upload, and a spoken answer that matches the scene (D, manual check on 3 scenes).
- 问一下 gives an answer without any voice input (D).
- No image is sent except at a question (F-20 row 2): opening/previewing alone sends nothing (unit +
  network log).
- Without permission or key, the matching sentence from §8 is spoken and nothing is claimed (unit).
- Closing the window stops the capture session; the green camera indicator disappears (D).
- A second question while one is in flight cancels the first; only the second answer is spoken (unit).

## 11. Existing Android tests
`T/vision/QianfanVisionClientTest`, `CameraQuestionHandlerTest`, `CameraLookMergeTest` (behaviour reference).

## 12. Source references (Android)
`A/ui/CameraPreviewView.kt` (preview window), `A/vision/CameraQuestionHandler.kt`, `A/tools/VisionDomain.kt`.

## 13. Implementation constraints
- Capture code only in NovaPlatform/Camera; vision HTTP clients in NovaServices; the question handler
  (cancel, one-in-flight, result shape) is pure Swift in NovaTools/Vision with fakes (T-071).
- The preview must not run while the window is closed (privacy, battery).
- Front-facing (selfie) camera is out of scope; a later toggle may add it.

## Open questions
- OQ-CAM-1 (OWNER): Gemini as the default vision backend instead of Qianfan? Recommendation: yes —
  the key is already stored and it understands Chinese questions well; keep Qianfan as an option.
- OQ-CAM-2 (OWNER): should a camera question while the window is closed open it automatically
  (proposed: yes), or answer without showing the preview?

## Tasks (to add to implementation-plan.md / work.json when approved)
| ID | Task | Verification |
|---|---|---|
| T-071a | `CameraQuestionHandler` (pure): one in flight, cancel, result/codes | unit |
| T-071b | `CameraSession` adapter (AVCaptureSession, still capture, stop on close) | build, D |
| T-071c | `GeminiVisionClient` (+ Qianfan option) behind `VisionPort` | unit, contract |
| T-071d | Camera icon, floating preview window, 问一下, wiring to `describe_camera_view` | S, D |
