import Foundation
import NovaKit
import NovaPorts
import NovaVoice

/// Non-secret settings keys in `SettingsStore` (UserDefaults).
public enum SettingsKey {
    public static let geminiConsentAccepted = "gemini_consent_accepted"
    public static let geminiModel = "gemini_model"
    public static let azureVoice = "azure_voice"
    public static let personaStyle = "persona_style"
    /// F-07 §14 item 2 (T-020a): `qwen` or `azure`; unset until the driver picks one.
    public static let voiceSource = "voice_source"
    /// F-07 §14 item 2: the 百炼 workspace API Host (not a secret).
    public static let qwenTTSHost = "qwen_tts_host"
    public static let qwenVoice = "qwen_voice"
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
    /// F-07 §14 item 5: the chosen source of her voice is ready (「她的声音」).
    public var voice: Bool
    public var amapSDKKey: Bool
    public var amapWebKey: Bool
    public var wakeAppID: Bool
    public var vision: Bool

    public init(credentials: any CredentialStore, settings: any SettingsStore) {
        func has(_ key: CredentialKey) -> Bool { SecretField.display(key, in: credentials) == .saved }
        geminiKey = has(.geminiAPIKey)
        geminiConsent = settings.bool(SettingsKey.geminiConsentAccepted) == true
        let azureReady = has(.azureSpeechKey) && settings.string(SettingsKey.azureVoice)?.isEmpty == false
        let choice = settings.string(SettingsKey.voiceSource).flatMap(VoiceSourceKind.init(rawValue:))
        switch VoiceSource.effectiveChoice(choice, hasQwenKey: has(.qwenAPIKey), hasAzureKey: has(.azureSpeechKey)) {
        case .qwen: voice = has(.qwenAPIKey) && VoiceHostCheck.isValid(settings.string(SettingsKey.qwenTTSHost) ?? "")
        case .azure: voice = azureReady
        }
        amapSDKKey = has(.amapSDKKey)
        amapWebKey = has(.amapWebKey)
        wakeAppID = has(.iflytekAppID) && has(.iflytekAPIKey) && has(.iflytekAPISecret)
        vision = has(.zhipuKey) || has(.geminiAPIKey) || has(.qianfanKey)
    }

    /// Why a session cannot start, or nil. Consent is checked first (F-22 §10 row 3).
    public var sessionBlocker: SessionErrorCode? {
        if !geminiConsent { return .geminiConsentMissing }
        if !geminiKey { return .geminiKeyMissing }
        return nil
    }

    /// Replies are revoiced only when the chosen voice source is configured (ADR-016, F-07 §14 item 5).
    public var revoicing: Bool { voice }
}
