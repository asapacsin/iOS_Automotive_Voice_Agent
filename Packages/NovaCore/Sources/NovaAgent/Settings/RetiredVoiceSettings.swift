import NovaKit
import NovaPorts
import NovaVoice

/// F-07 §17 item 3 (T-020d): the one-time cleanup of the removed TTS source on installed phones. This file and its
/// test are the only Swift files allowed to name it (§17 item 6 gate, `scripts/gates/check_imports.py`).
public enum RetiredVoiceSettings {
    /// Set only after the Keychain delete succeeded or found no item, so a failed delete is tried again next launch.
    public static let doneKey = "azure_removed_done"
    public static let keychainAccount = "azure_speech_key"
    public static let retiredDefaults = ["azure_region", "azure_voice"]
    public static let retiredSource = "azure"

    /// A saved retired source becomes Gemini 原声, its settings and key go. Logs nothing (I-8).
    public static func run(credentials: any CredentialStore, settings: any SettingsStore) {
        guard settings.bool(doneKey) != true else { return }
        if settings.string(SettingsKey.voiceSource) == retiredSource {
            settings.set(VoiceSourceKind.gemini.rawValue, for: SettingsKey.voiceSource)
        }
        for key in retiredDefaults { settings.set(nil as String?, for: key) }
        do { try credentials.removeRetired(account: keychainAccount) } catch { return }
        settings.set(true, for: doneKey)
    }
}
