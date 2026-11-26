import NovaKit
import NovaPorts

/// F-07 §18 item 4 (T-020e): the one-time cleanup of 「她的声音」 on installed phones. On the first launch of this build,
/// once (remembered under `voice_source_removed_done`), the saved source, the 千问 TTS host and voice, and the two
/// earlier one-time flags are removed. The Keychain 百炼 key is kept (search and the Qwen voice model use it). Logs
/// nothing about the values (I-8). This file and its test are the only Swift files allowed to name the retired keys
/// (§18 item 6 gate, `scripts/gates/check_imports.py`).
public enum VoiceSourceRemoval {
    public static let doneKey = "voice_source_removed_done"
    /// The removed UserDefaults keys (item 4).
    public static let retiredDefaults = ["voice_source", "qwen_tts_host", "qwen_voice"]
    /// The earlier one-time flags: F-07 §15 item 2's move to Gemini 原声 and F-07 §17's cleanup.
    public static let retiredFlags = ["voice_source_gemini_default_done", RetiredVoiceSettings.doneKey]

    /// Removes the values once; a second launch changes nothing. `credentials` is never touched.
    public static func run(settings: any SettingsStore) {
        guard settings.bool(doneKey) != true else { return }
        for key in retiredDefaults + retiredFlags { settings.set(nil as String?, for: key) }
        settings.set(true, for: doneKey)
    }
}
