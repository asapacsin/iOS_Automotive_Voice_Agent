# F-20a Camera button, live preview window and "what is there?" questions

**Status:** APPROVED (iOS only, 2026-10-26; OQ-CAM-1/2 answered by the owner). Extends [F-20 Camera vision questions](vision.md); the
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
- Vision backend behind `VisionPort`: **superseded by §14** (GLM-4.6V-Flash → Gemini `gemini-3.5-flash-lite` →
  Qianfan through `VisionChain`). Original text kept for history:
  - Default **Gemini** `generateContent` (model `gemini-flash-latest`, image + question, system text
    「只根据图片回答，看不清就说看不清，不要猜。用一两句中文口语回答。」), same Keychain key as Live.
  - Optional **Qianfan** (F-20 Android parity) when a Qianfan key is saved.
- Answer voiced through the normal reply path (Gemini Live → revoicer → Azure). The tap path (as built
  2026-10-26) shows the answer as her bubble and speaks it in her Azure voice while a session runs; with no
  session it is shown on the window only. Sending it to the model as text is a later option.

## 8. Error handling and recovery
Updated by §14 (vision fallback chain); the table below follows §14 item 4.
| Case | Result / what she says |
|---|---|
| No permission | `CAMERA_PERMISSION_DENIED`: 「摄像头没有权限，请在设置里允许。」 |
| Camera busy / start failed | `CAMERA_UNAVAILABLE`: 「摄像头现在用不了。」 |
| No vision key | `NOT_CONFIGURED` (VisionAnswer.notConfigured): 「看图功能还没有配置。」 |
| Auth failure (401/403) | `AUTH_FAILED`: 「看图服务的密钥无效。」 |
| Busy (429/5xx), timeout (8 s) / network | `VISION_BUSY`: 「识图服务现在忙或者连不上，等一下再问我。」 (§14 item 4) |
| Other backend failure | `VISION_FAILED`: 「这次看图没有成功，再问我一次吧。」 (§14 item 4) |
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
- The front-facing (selfie) lens as a 后方 view is added by [F-20b](camera-rear.md) (2026-10-27).

## Open questions
- OQ-CAM-1 (SUPERSEDED 2026-10-31 by §14; ANSWERED 2026-10-26: **Gemini default**, Qianfan optional): Gemini as the default vision backend instead of Qianfan? Recommendation: yes —
  the key is already stored and it understands Chinese questions well; keep Qianfan as an option.
- OQ-CAM-2 (ANSWERED 2026-10-26: **yes, the question opens the window**): should a camera question while the window is closed open it automatically
  (proposed: yes), or answer without showing the preview?

## Tasks (in implementation-plan.md M6 and specs/work.json)
| ID | Task | Verification |
|---|---|---|
| T-071a | `CameraQuestionHandler` (pure): one in flight, cancel, result/codes | unit |
| T-071b | `CameraSession` adapter (AVCaptureSession, still capture, stop on close) | build, D |
| T-071c | `GeminiVisionClient` (+ Qianfan option) behind `VisionPort` | unit, contract |
| T-071d | Camera icon, floating preview window, 问一下, wiring to `describe_camera_view` | S, D |
| T-071h | Vision backends: GLM-4.6V-Flash first, then Gemini (pinned), then Qianfan; honest busy wording (§14) | unit, build, D |

## 14. Vision backends: GLM-4.6V-Flash first, then a different service (iOS, APPROVED 2026-10-31)

**Why.** Device run e00fc27 (2026-10-31 17:43–17:44): camera questions now reach the tool (F-21 §15 works:
`toolCall name=describe_camera_view camera=front_view` at 17:43:49 and 17:44:07), the still is taken, but both
requests to Gemini `gemini-flash-latest` got **HTTP 503** (after 3.6 s and 2.4 s), so the tool returned
`VISION_FAILED` and she said 「刚才没看清楚」 although nothing was looked at. Causes:
- **One backend, no fallback.** `PreferredVision` uses Gemini whenever a Gemini key is saved and never tries anything
  else when Gemini fails; Qianfan is only used when there is no Gemini key.
- **A moving alias.** `gemini-flash-latest` follows Google's newest Flash model, which is the most loaded one.
- **Every failure sounds like a blurry photo.** Busy, timeout and network all map to 「刚才没看清楚」.
Community review 2026-10-31: 503 "high demand" is reported on every Gemini tier, including GA 3.5 Flash-Lite and paid
priority 3.7 Flash (Google AI Developers Forum); Google classes 503 as temporary overload; the common client fix is to
move to a different model or service, since separate services are rarely busy at the same moment. Zhipu
GLM-4.6V-Flash is a vision model listed as free on Zhipu's pricing page (128K context), hosted in China (no VPN for
this request), OpenAI-style chat API. Owner 2026-10-31: prefers GLM-4.6V-Flash; "just write this into spec". The
owner already has a Zhipu standard API key (兼容) and enters it in 设置; it is never written in the repository or chat.

**Rule in plain words.** A camera question goes to GLM-4.6V-Flash first. If it is busy, slow or refuses, the same
photo goes to Gemini (a fixed stable model) within the same 8 seconds. Only when every service fails does she say so,
and she says why (busy, wrong key, not set up), never 「没看清楚」 for a photo nobody looked at.

1. **Zhipu key (settings).** New `CredentialKey.zhipuKey = "zhipu_key"` (Keychain, write-only like the others, removed
   by `CredentialWipe` through `CaseIterable`). 设置 shows it as 「智谱 key（视觉，推荐）」, first among the vision keys;
   the Qianfan field stays 「千帆 key（可选，视觉备用）」. `SettingsReadiness.vision` is true when any of the Zhipu,
   Gemini or Qianfan keys is saved (today: Qianfan only).
2. **`GLMVisionClient` (NovaServices, `VisionPort`).**
   - `POST https://open.bigmodel.cn/api/paas/v4/chat/completions`, header `Authorization: Bearer <key>`,
     `Content-Type: application/json`; the key is read per request (a key saved in 设置 works without a restart).
   - Body: `model: "glm-4.6v-flash"`, `thinking: {"type": "disabled"}` (fast answers; Zhipu's examples enable it),
     `messages`: system = `GeminiVisionClient.systemText` (same wording for every backend), user = `content` array with
     `{"type":"image_url","image_url":{"url": <base64 JPEG>}}` then `{"type":"text","text": <question>}`. The image is
     sent as plain base64 as in Zhipu's official example; if a device run shows HTTP 400 for it, the implementer switches
     to a `data:image/jpeg;base64,` URL and records the finding in the PR.
   - Answer: `choices[0].message.content` (string), trimmed; GLM box markers `<|begin_of_box|>` / `<|end_of_box|>`
     removed; `reasoning_content` ignored; empty → failed.
   - Status mapping: 200 with text → `.answer`; 401/403 → `.authFailed`; 429, 5xx, timeout, network error → `.busy`
     (new case, item 4); other → `.failed`. No key → `.notConfigured` (the backend is skipped, item 3).
3. **Order and time budget (`VisionChain`, replaces `PreferredVision`).** Backends in order **GLM → Gemini → Qianfan**,
   each only when its key is saved; the order is one list in `AgentRuntime` so it can be changed later.
   - The whole question keeps the existing 8 s deadline (`CameraQuestionHandler.withDeadline`). The first backend gets
     at most 4.5 s; each next backend gets the time left, and is not tried if less than 1.5 s is left.
   - Move to the next backend on `.busy`, `.failed` and `.authFailed`; stop at the first `.answer`. No second request to
     the same backend for one question (moving to another service is the retry).
   - Result when none answered: any `.busy` → `.busy`; else any `.authFailed` → `.authFailed`; else `.failed`; no
     backend with a key → `.notConfigured`.
   - A newer question or closing the window cancels the chain (unchanged §9).
4. **Honest failure wording.** `VisionAnswer` gains `.busy`; `ToolErrorCode` gains `VISION_BUSY`.
   `CameraQuestionHandler` maps:
   | Result | Code | Advice she speaks from |
   |---|---|---|
   | `.busy` | `VISION_BUSY` | 「识图服务现在忙或者连不上，等一下再问我。请如实说明，不要描述画面。」 |
   | `.failed` | `VISION_FAILED` | 「这次看图没有成功，再问我一次吧。请如实说明，不要描述画面。」 |
   | `.authFailed` | `AUTH_FAILED` | unchanged 「看图服务的密钥无效。」 |
   | `.notConfigured` | `NOT_CONFIGURED` | unchanged 「看图功能还没有配置。」 |
   A model answer that it cannot tell what is in the photo is still spoken as is (§8, I-1).
5. **Gemini pinned.** `GeminiVisionClient.defaultModel = "gemini-3.5-flash-lite"` (GA, Google retirement date July
   2027 or later) instead of `gemini-flash-latest`; never a `-latest` alias. Its 429/5xx/timeout map to `.busy` too.
   Qianfan keeps its model and gets the same `.busy` mapping.
6. **Logs.** Per attempt `visionAttempt backend=glm|gemini|qianfan result=answer|busy|auth|failed status=<http|timeout|
   network> ms=<n>`; per question `visionResult backend=<answered by|none> code=<code> totalMs=<n>`. Never the image,
   the question, the answer text, the URL query or a key (I-7, I-8).
7. **Docs.** §7 (vision backend) and §8 (error table) and OQ-CAM-1 are superseded by this section; edit §7 and §8 to
   point here. The Qianfan F-20 parity notes stay.
8. **Out of scope.** Streaming video to a model; a paid Gemini tier; the voice session's own network handling (F-24).

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Chain with fakes: GLM answers | Answer returned; Gemini and Qianfan not called | unit (VisionChain) |
| 2 | GLM `.busy` (503), Gemini answers | Gemini's answer; two `visionAttempt` lines, `visionResult backend=gemini` | unit |
| 3 | GLM 429, Gemini 503, no Qianfan key | `VISION_BUSY`, advice 「识图服务现在忙…」; never 「没看清楚」 | unit (chain + handler) |
| 4 | GLM hangs | GLM cut at 4.5 s; Gemini gets ≤ 3.5 s; whole question ≤ 8 s (fake clock) | unit |
| 5 | Only a Gemini key saved | No GLM request; Gemini asked | unit |
| 6 | No vision key at all | `NOT_CONFIGURED` | unit |
| 7 | GLM 401, Gemini answers / GLM 401, Gemini 503 | Answer / `VISION_BUSY` (busy wins over auth) | unit |
| 8 | GLM request encoding | URL, Bearer header, `model` `glm-4.6v-flash`, `thinking.type` `disabled`, image part before text part, system text equal to Gemini's; response with box markers → markers removed; empty content → `.failed` | unit (HTTPTransport fake) |
| 9 | Gemini client | `defaultModel == "gemini-3.5-flash-lite"`; 503 → `.busy` | unit |
| 10 | Settings | 「智谱 key（视觉，推荐）」 field saves to Keychain, never shown again; `CredentialWipe` removes it; readiness `vision` true with any one of the three keys | unit + S |
| 11 | Log capture during rows 1–4 | No image bytes, question, answer text or key in any line | unit |
| 12 | Device, 智谱 key saved: 10 camera questions (front and 后面) in one drive | ≥ 9 answered from the picture; log shows the backend per question and `totalMs`; median recorded in the PR / checklist | D |
| 13 | Device: 智谱 key removed (only Gemini) | Camera questions answered by Gemini (`backend=gemini`) | D |
| 14 | Device: wrong 智谱 key saved | Answered by Gemini; log `backend=glm result=auth` then `backend=gemini result=answer` | D |
| 15 | Device: checklist 6-03…6-06 | Pass | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-071h | §14 items 1–7: `zhipuKey` + 设置 field + readiness, `GLMVisionClient`, `VisionChain` (GLM → Gemini → Qianfan, 4.5 s / 1.5 s budget inside 8 s), `.busy` + `VISION_BUSY` and the new advice texts, Gemini pinned to `gemini-3.5-flash-lite`, vision logs, §7/§8 edits; unit rows 1–11; device rows 12–15 | unit, build, D (rows 12–15) |
