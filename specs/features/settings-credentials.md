# F-22 Settings, credentials and consent

**Android status:** IMPLEMENTED. Gemini card added 2026-10-22; Qwen card hidden while frozen.
**Depends on:** architecture.md (Persistence)

## 1. Purpose
Let the owner enter keys and consent, see readiness, and wipe secrets.

## 2. User-facing behaviour
Developer settings cards: status, Gemini (consent, key, model), persona, Amap, wake, vision, diagnostics, danger (清除所有密钥).

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
- Keys never shown after save; blank field keeps the stored value.
- Wipe clears every secret listed in CredentialWipe.
- Session cannot start without consent (GEMINI_CONSENT_MISSING).

## 11. Existing Android tests
`T/DeveloperSettingsStatusTest`, `GeminiSettingsTest`, `QwenSettingsTest`, `AzureSpeechSettingsTest`.

## 12. Source references (Android)
`A/DeveloperSettingsActivity.kt`; `A/DeveloperSettingsStatus.kt`; `A/GeminiSettings.kt`; `A/AndroidKeystoreCredentialStore.kt:26`; `A/CredentialWipe.kt:12-22`.

## 13. Implementation constraints
None beyond the contracts.

## iOS notes (PROPOSED unless labelled)
Keychain + UserDefaults; SwiftUI Form (B). No secrets in source, logs or the app bundle (I-7).
