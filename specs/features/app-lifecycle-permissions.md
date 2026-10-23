# F-23 App lifecycle, background and permissions

**Android status:** IMPLEMENTED: foreground service type microphone, START_NOT_STICKY; no boot start; no accessibility service.
**Depends on:** ios-feasibility.md

## 1. Purpose
Keep the voice session alive while the app is in use, ask for permissions when needed, shut down cleanly.

## 2. User-facing behaviour
Notification permission at start, location at start, microphone and camera on first need; a config banner when settings are incomplete.

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
- Permission prompts appear only when needed and the app explains a denial.
- Backgrounding behaviour matches the decision in ios-feasibility.md (documented, tested on device).

## 11. Existing Android tests
Lifecycle rows mostly HUMAN/NOT_RUN (PROCDEATH-001 NOT_RUN).

## 12. Source references (Android)
`A/MainActivity.kt:38,155-156,180,192,196,206,237,304,331,340`; `A/VoiceSessionService.kt:30,39,67`; `app/src/main/AndroidManifest.xml`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
iOS has no foreground service; background audio mode + active audio session is the closest (PROPOSED, App Review risk; OQ-IOS-4).
