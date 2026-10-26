# F-23 App lifecycle, background and permissions

**Android status:** IMPLEMENTED: foreground service type microphone, START_NOT_STICKY; no boot start; no accessibility service.
**Depends on:** ios-feasibility.md

## 1. Purpose
Keep the voice session alive while the app is in use, ask for permissions when needed, shut down cleanly.

## 2. User-facing behaviour
Notification permission at start, location at start, microphone and camera on first need; a config banner when settings are incomplete.

## 3. Preconditions
Background policy (OQ-IOS-4, ANSWERED with review risk): `UIBackgroundModes` `audio` + `location`, used only
while a voice session or route guidance is active (App Review guideline 2.5.4); the mic indicator stays
visible; no background listening just for the wake word; `allowsBackgroundLocationUpdates = true` during
guidance so it continues with the screen locked; the use is described in the review notes.

## 4. Inputs and outputs
Permissions and their purpose strings (Info.plist via `App/project.yml`):
- Microphone `NSMicrophoneUsageDescription` (present): first 开始对话.
- Location When In Use `NSLocationWhenInUseUsageDescription` (PROPOSED): first navigation / weather here.
- Camera `NSCameraUsageDescription` (PROPOSED, F-20a): first camera tap.
- Contacts `NSContactsUsageDescription` (PROPOSED, F-19): first call.
Out: a config banner on the drive screen when `SettingsReadiness` blocks a session.

## 5. State transitions
App: active → inactive → background → (suspended). Session: started on 开始对话; stopped on 结束对话, on
background unless background audio is kept (PROPOSED: only while NAVIGATING), and on termination.

## 6. Events and triggers
Scene phase changes, audio session interruptions (call, Siri) and route changes, permission results.

## 7. Dependencies and external services
`AVAudioSession` (playAndRecord, voice processing), `UIBackgroundModes: audio` (PROPOSED, App Review risk),
CoreLocation, AVFoundation camera.

## 8. Error handling and recovery
- Denied permission → the feature returns its permission code and the UI explains how to allow it in
  Settings; the rest of the app keeps working.
- Audio interruption → the uplink pauses; it resumes when the interruption ends with shouldResume.

## 9. Concurrency, cancellation, timeouts
The camera stops within 1 s of closing or backgrounding; the session socket closes on background unless
background audio is kept (T-062, T-064 device rows).

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
