# F-22 Settings, credentials and consent

**Android status:** IMPLEMENTED. Gemini card added 2026-10-22; Qwen card hidden while frozen.
**Depends on:** architecture.md (Persistence)

## 1. Purpose
Let the owner enter keys and consent, see readiness, and wipe secrets.

## 2. User-facing behaviour
Developer settings cards: status, Gemini (consent, key, model), persona, Amap, wake, vision, diagnostics, danger (清除所有密钥).

## 3. Preconditions
None; the 设置 tab is always reachable.

## 4. Inputs and outputs
- Secrets (Keychain, `KeychainCredentialStore`): Gemini API key, Azure Speech key, Amap SDK key, Amap Web key,
  iFlytek app id, iFlytek APIKey and APISecret (AIKit wake word, T-060), Qianfan key.
- Non-secrets (UserDefaults): `gemini_consent_accepted`, `gemini_model`, `azure_voice`, `persona_style`.
- Out: `SettingsReadiness` (status card: which items are set) and `sessionBlocker`.

## 5. State transitions
Per secret: notSet ↔ saved (「已保存」). Consent: not accepted → accepted; wipe → not accepted.

## 6. Events and triggers
Save per card, consent toggle, 清除所有密钥 (with a confirmation dialog).

## 7. Dependencies and external services
iOS Keychain (this-device-only accessibility, PROPOSED), UserDefaults. The Azure region is detected from the key.

## 8. Error handling and recovery
- A blank field on save keeps the stored value; values are never displayed after save (`SecretField`).
- Session start: no consent → `GEMINI_CONSENT_MISSING` (checked first), no key → `GEMINI_KEY_MISSING`.
- Wipe tries every key and reports the ones it could not remove; consent is cleared too.
- A Keychain error is shown as a short message; the key never appears in logs (I-7, I-8).

## 9. Concurrency, cancellation, timeouts
Settings are read when a session starts; a change while a session runs applies at the next start.

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
