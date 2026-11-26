import NovaKit
import NovaPorts

/// F-07 §17 item 3 (T-020d): the one-time cleanup of the removed TTS source on installed phones. This file and its
/// test are the only Swift files allowed to name it (§17 item 6 gate, `scripts/gates/check_imports.py`).
public enum RetiredVoiceSettings {
    /// Set only after the Keychain delete succeeded or found no item, so a failed delete is tried again next launch.
    public static let doneKey = "azure_removed_done"
    public static let keychainAccount = "azure_speech_key"
    public static let retiredDefaults = ["azure_region", "azure_voice"]
    public static let retiredSource = "azure"

    /// Its settings and key go (F-07 §18 item 4 then removes the saved source itself). Logs nothing (I-8). A failed
    /// Keychain delete is retried next launch (§17); after the F-07 §18 cleanup removed the flag, one more run finds
    /// nothing to delete and sets it again.
    public static func run(credentials: any CredentialStore, settings: any SettingsStore) {
        guard settings.bool(doneKey) != true else { return }
        for key in retiredDefaults { settings.set(nil as String?, for: key) }
        do { try credentials.removeRetired(account: keychainAccount) } catch { return }
        settings.set(true, for: doneKey)
    }
}
