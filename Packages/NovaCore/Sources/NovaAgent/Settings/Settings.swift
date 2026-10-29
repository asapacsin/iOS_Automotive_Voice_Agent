import Foundation
import NovaKit
import NovaPorts

/// Non-secret settings keys in `SettingsStore` (UserDefaults).
public enum SettingsKey {
    public static let geminiConsentAccepted = "gemini_consent_accepted"
    public static let geminiModel = "gemini_model"
    public static let azureVoice = "azure_voice"
    public static let personaStyle = "persona_style"
}

/// A write-only secret field (F-22 §10 row 1): the stored value is never shown again, and saving a
/// blank field keeps what is stored.
public enum SecretField {
    public enum Display: Sendable, Hashable {
        case notSet
        /// 「已保存」: a value exists; the UI shows this, never the value.
        case saved
    }

    public static func display(_ key: CredentialKey, in store: any CredentialStore) -> Display {
        ((try? store.value(for: key)) ?? nil)?.isEmpty == false ? .saved : .notSet
    }

    /// Applies the field's content on save. Returns true when the store changed.
    @discardableResult
    public static func save(_ input: String, for key: CredentialKey, in store: any CredentialStore) throws -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        try store.set(trimmed, for: key)
        return true
    }
}

/// `A/CredentialWipe.kt:12-22`: removes every stored secret and the Gemini consent.
public enum CredentialWipe {
    /// Keys that could not be removed; empty on success. Every key is attempted even after a failure.
    @discardableResult
    public static func wipe(_ credentials: any CredentialStore, settings: any SettingsStore) -> [CredentialKey] {
        var failed: [CredentialKey] = []
        for key in CredentialKey.allCases {
            do { try credentials.remove(key) } catch { failed.append(key) }
        }
        settings.set(false, for: SettingsKey.geminiConsentAccepted)
        return failed
    }
}

/// What the status card shows and whether a session may start (`A/DeveloperSettingsStatus.kt`).
public struct SettingsReadiness: Sendable, Hashable {
    public var geminiKey: Bool
    public var geminiConsent: Bool
    public var azureVoice: Bool
    public var amapSDKKey: Bool
    public var amapWebKey: Bool
    public var wakeAppID: Bool
    public var vision: Bool

    public init(credentials: any CredentialStore, settings: any SettingsStore) {
        func has(_ key: CredentialKey) -> Bool { SecretField.display(key, in: credentials) == .saved }
        geminiKey = has(.geminiAPIKey)
        geminiConsent = settings.bool(SettingsKey.geminiConsentAccepted) == true
        azureVoice = has(.azureSpeechKey) && settings.string(SettingsKey.azureVoice)?.isEmpty == false
        amapSDKKey = has(.amapSDKKey)
        amapWebKey = has(.amapWebKey)
        wakeAppID = has(.iflytekAppID) && has(.iflytekAPIKey) && has(.iflytekAPISecret)
        vision = has(.qianfanKey)
    }

    /// Why a session cannot start, or nil. Consent is checked first (F-22 §10 row 3).
    public var sessionBlocker: SessionErrorCode? {
        if !geminiConsent { return .geminiConsentMissing }
        if !geminiKey { return .geminiKeyMissing }
        return nil
    }

    /// Replies are revoiced only when an Azure key and voice are configured (ADR-016).
    public var revoicing: Bool { azureVoice }
}
