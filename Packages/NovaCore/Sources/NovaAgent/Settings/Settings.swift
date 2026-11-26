import Foundation
import NovaKit
import NovaPorts
import NovaVoice

/// Non-secret settings keys in `SettingsStore` (UserDefaults).
public enum SettingsKey {
    public static let geminiConsentAccepted = "gemini_consent_accepted"
    public static let geminiModel = "gemini_model"
    public static let personaStyle = "persona_style"
    /// F-05 §15 item 1 (T-016q): 「语音模型」, a `VoiceModel` raw value; unset reads as Gemini.
    public static let voiceModel = "voice_model"
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
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // F-18 §31 item 1: the 和风 host is saved without `https://` and without a trailing `/`.
        if key == .qweatherHost { trimmed = QWeatherHost.normalized(trimmed) }
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
        // F-07 §17 item 3: the removed TTS key too, in case the launch cleanup has not deleted it yet.
        try? credentials.removeRetired(account: RetiredVoiceSettings.keychainAccount)
        settings.set(false, for: SettingsKey.geminiConsentAccepted)
        return failed
    }
}

/// What the status card shows and whether a session may start (`A/DeveloperSettingsStatus.kt`).
public struct SettingsReadiness: Sendable, Hashable {
    public var geminiKey: Bool
    public var geminiConsent: Bool
    public var amapSDKKey: Bool
    public var amapWebKey: Bool
    /// F-18 §31 item 1: 和风天气 host and key both saved.
    public var qweather: Bool
    public var wakeAppID: Bool
    public var vision: Bool

    public init(credentials: any CredentialStore, settings: any SettingsStore) {
        func has(_ key: CredentialKey) -> Bool { SecretField.display(key, in: credentials) == .saved }
        geminiKey = has(.geminiAPIKey)
        geminiConsent = settings.bool(SettingsKey.geminiConsentAccepted) == true
        amapSDKKey = has(.amapSDKKey)
        amapWebKey = has(.amapWebKey)
        qweather = has(.qweatherHost) && has(.qweatherKey)
        wakeAppID = has(.iflytekAppID) && has(.iflytekAPIKey) && has(.iflytekAPISecret)
        vision = has(.zhipuKey) || has(.geminiAPIKey) || has(.qianfanKey)
    }

    /// Why a session cannot start, or nil. Consent is checked first (F-22 §10 row 3).
    public var sessionBlocker: SessionErrorCode? {
        if !geminiConsent { return .geminiConsentMissing }
        if !geminiKey { return .geminiKeyMissing }
        return nil
    }

    /// F-07 §18 item 1 (T-020e): her voice is always the voice model's own audio through the claim gate; nothing
    /// revoices a reply.
    public var revoicing: Bool { false }
}

/// F-18 §31 item 1 (T-046t): `https://abc.qweatherapi.com/` → `abc.qweatherapi.com`.
public enum QWeatherHost {
    public static func normalized(_ input: String) -> String {
        var h = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where h.lowercased().hasPrefix(scheme) { h = String(h.dropFirst(scheme.count)) }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }
}
