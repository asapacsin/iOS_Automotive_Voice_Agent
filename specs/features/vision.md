# F-20 Camera vision questions

**Android status:** IMPLEMENTED (JVM). 2 of 3 vision rows NOT_RUN.
**Depends on:** contracts/api-contracts.md (Qianfan)

## 1. Purpose
Answer questions about what the camera sees.

## 2. User-facing behaviour
前面那是什么车 → camera look → answer; images sent only on open and on a question.

## 3. Preconditions
See depends-on contracts.

## 4. Inputs and outputs
See refs.

## 5. State transitions
See contracts.

## 6. Events and triggers
Tool call or UI event.

## 7. Dependencies and external services
See contracts/api-contracts.md.

## 8. Error handling and recovery
Errors are ok=false results with codes; see refs.

## 9. Concurrency, cancellation, timeouts
See contracts.

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
