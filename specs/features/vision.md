# F-20 Camera vision questions

**Android status:** IMPLEMENTED (JVM). 2 of 3 vision rows NOT_RUN.
**Depends on:** contracts/api-contracts.md (Qianfan)

## 1. Purpose
Answer questions about what the camera sees.

## 2. User-facing behaviour
前面那是什么车 → camera look → answer; images sent only on open and on a question.

## 3. Preconditions
- Camera permission (`NSCameraUsageDescription`); denied → `CAMERA_PERMISSION_DENIED`.
- A vision key: Qianfan (Android parity) or Gemini (iOS default proposed in F-20a OQ-CAM-1).
  None → `NotConfigured`.

## 4. Inputs and outputs
- In: `describe_camera_view(question)` (non-blank, length-limited: `BLANK_QUESTION` / `QUESTION_TOO_LONG`)
  and one still frame (JPEG, longest side ≤ 1024 px, not older than 1 s).
- Out: `{ok:true, answer, seen_at_ms}`, or ok=false with `NOT_CONFIGURED`, `AUTH_FAILED`,
  `VISION_FAILED`, `CAMERA_UNAVAILABLE`, `CAMERA_PERMISSION_DENIED`. `VisionPort` results:
  Answer, NotConfigured, AuthFailed, Failed.
- `describe_camera_view` is not an acting tool: its result never proves an action claim (F-06).

## 5. State transitions
Per question: idle → capturing → asking → idle. Preview window states are in F-20a §5.

## 6. Events and triggers
`describe_camera_view` tool call; camera open / 问一下 tap (F-20a).

## 7. Dependencies and external services
Qianfan `POST https://qianfan.baidubce.com/v2/chat/completions` (bearer token, image as JPEG);
Gemini `generateContent` (F-20a); `AVCaptureSession` in NovaPlatform/Camera; HTTP clients in NovaServices.

## 8. Error handling and recovery
| Case | Code | What she says |
|---|---|---|
| No permission | `CAMERA_PERMISSION_DENIED` | 「摄像头没有权限，请在设置里允许。」 |
| Camera busy / start failed | `CAMERA_UNAVAILABLE` | 「摄像头现在用不了。」 |
| No vision key | `NOT_CONFIGURED` | 「看图功能还没有配置。」 |
| Auth failure (401/403) | `AUTH_FAILED` | 「看图服务的密钥无效。」 |
| Timeout (8 s) / network | `VISION_FAILED` | 「刚才没看清楚，再问我一次吧。」 |

If the model cannot tell, the answer says so; it never
guesses (I-1). The image and question are never logged (I-8).

## 9. Concurrency, cancellation, timeouts
8 s deadline; one request in flight, a newer question cancels the older one and its answer is dropped;
barge-in stops speaking the answer (F-08).

## 10. Acceptance criteria (iOS)
- No key → NotConfigured sentence; auth failure → AuthFailed sentence.
- No image is sent except on camera open or a camera question.

## 11. Existing Android tests
`T/vision/QianfanVisionClientTest`, `CameraQuestionHandlerTest`, `CameraLookMergeTest`.

## 12. Source references (Android)
`A/vision/VisionPort.kt:9,31`; `A/vision/QianfanVisionClient.kt:27,47,65`; `A/vision/CameraQuestionHandler.kt`; `A/tools/VisionDomain.kt`; `A/ui/CameraPreviewView.kt`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
`AVCaptureSession` photo/frame capture (B). Qianfan is HTTP (A).

**iOS extension:** the camera icon, live preview window and tap-to-ask flow are specified in [F-20a](camera-view.md) (PROPOSED).
