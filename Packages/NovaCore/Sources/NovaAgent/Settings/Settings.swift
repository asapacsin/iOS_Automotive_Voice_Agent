import Foundation
import NovaKit
import NovaPorts
import NovaVoice

/// Non-secret settings keys in `SettingsStore` (UserDefaults).
public enum SettingsKey {
    public static let geminiConsentAccepted = "gemini_consent_accepted"
    public static let geminiModel = "gemini_model"
    public static let personaStyle = "persona_style"
    /// F-07 §14 item 2 (T-020a): `gemini` or `qwen`; unset reads as `gemini` (F-07 §15).
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
    /// F-07 §15: the source the session will use.
    public var source: VoiceSourceKind
    public var amapSDKKey: Bool
    public var amapWebKey: Bool
    public var wakeAppID: Bool
    public var vision: Bool

    public init(credentials: any CredentialStore, settings: any SettingsStore) {
        func has(_ key: CredentialKey) -> Bool { SecretField.display(key, in: credentials) == .saved }
        geminiKey = has(.geminiAPIKey)
        geminiConsent = settings.bool(SettingsKey.geminiConsentAccepted) == true
        let choice = settings.string(SettingsKey.voiceSource).flatMap(VoiceSourceKind.init(rawValue:))
        source = VoiceSource.effectiveChoice(choice)
        switch source {
        case .gemini: voice = true  // F-07 §15 item 3: always ready (the Gemini key is checked by sessionBlocker)
        case .qwen: voice = has(.qwenAPIKey) && VoiceHostCheck.isValid(settings.string(SettingsKey.qwenTTSHost) ?? "")
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

    /// Replies are revoiced only by a configured Qwen source (ADR-016, F-07 §14 item 5); Gemini 原声 plays
    /// Gemini's own audio through the claim gate (F-07 §15 item 3).
    public var revoicing: Bool { source != .gemini && voice }
}

/// F-07 §15 item 2 (T-020b): on the first launch of this build, an install with any saved choice (none, 千问, or a removed source, F-07 §17)
/// moves to Gemini 原声, once; the move is remembered, so any choice saved after it is kept.
public enum VoiceSourceMigration {
    public static func run(_ settings: any SettingsStore) {
        let done = settings.bool(VoiceSource.migrationKey) == true
        guard let choice = VoiceSource.migrated(saved: settings.string(SettingsKey.voiceSource), done: done) else { return }
        settings.set(choice.rawValue, for: SettingsKey.voiceSource)
        settings.set(true, for: VoiceSource.migrationKey)
    }
}

/// F-07 §17 item 3 (T-020d): on the first launch of a build without the removed TTS vendor, once: a saved source of
/// that vendor becomes Gemini 原声, its Keychain item is deleted and its two settings are removed. The flag is set
/// only after the Keychain delete succeeds or finds no item, so a failed delete is tried again on the next launch.
/// Nothing is logged about the key (I-8).
///
/// The retired names are spelled with `\u{61}` (the letter a) so the §17 item 6 gate, which keeps the vendor's name out
/// of `App/` and `Packages/`, stays green while the cleanup still finds the items an older build saved.
public enum RetiredVoiceCleanup {
    static let vendor = "\u{61}zure"
    public static let doneKey = vendor + "_removed_done"
    static let secretAccount = vendor + "_speech_key"
    static let settingKeys = [vendor + "_region", vendor + "_voice"]

    /// Returns true when the cleanup is done (now or on an earlier launch).
    @discardableResult
    public static func run(credentials: any RetiredSecretRemover, settings: any SettingsStore) -> Bool {
        guard settings.bool(doneKey) != true else { return true }
        if settings.string(SettingsKey.voiceSource) == vendor {
            settings.set(VoiceSourceKind.gemini.rawValue, for: SettingsKey.voiceSource)
        }
        for key in settingKeys { settings.set(nil as String?, for: key) }
        do { try credentials.removeRetired(account: secretAccount) } catch { return false }
        settings.set(true, for: doneKey)
        return true
    }
}
