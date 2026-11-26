import NovaKit
import NovaPorts
import NovaVoice

/// F-05 §15 item 1 (T-016q): 设置 「语音模型」, the model the voice session talks to. Stored on the phone; read at the
/// next connect (a running session is not switched). Pure.
public enum VoiceModel: String, Sendable, Hashable, CaseIterable {
    case geminiLive = "gemini-3.8-live"
    case qwenFlash = "qwen-audio-3.1-realtime-flash"
    case qwenPlus = "qwen-audio-3.1-realtime-plus"

    public static let settingsKey = "voice_model"
    public static let defaultModel = VoiceModel.geminiLive
    public static let title = "语音模型"
    /// Item 1: shown under the row; the choice applies at the next connect.
    public static let nextConnectNote = "下次连接时生效"
    /// Item 1: a Qwen choice without the 百炼 key.
    public static let qwenKeyMissing = "先在设置里填百炼 key"

    /// The model id sent to the provider (and written in the record header, item 6).
    public var modelID: String { rawValue }

    public var label: String {
        switch self {
        case .geminiLive: "Gemini 3.8 Live"
        case .qwenFlash: "Qwen Audio 3.1 Flash"
        case .qwenPlus: "Qwen Audio 3.1 Plus"
        }
    }

    public var isQwen: Bool { self != .geminiLive }

    /// Item 1 (changed 2026-11-26, T-016r): a Qwen choice needs only the 百炼 key; the saved 千问 voice API Host is
    /// not used.
    public func isAvailable(qwenKey: String?) -> Bool {
        guard isQwen else { return true }
        return qwenKey?.isEmpty == false
    }

    /// The disabled reason for the picker row; nil when the choice can be made.
    public func disabledReason(qwenKey: String?) -> String? {
        isAvailable(qwenKey: qwenKey) ? nil : Self.qwenKeyMissing
    }

    /// The stored choice; unset or unknown reads as Gemini (the default).
    public static func saved(in settings: any SettingsStore) -> VoiceModel {
        settings.string(settingsKey).flatMap(VoiceModel.init(rawValue:)) ?? defaultModel
    }

    /// The model the next connect uses: a Qwen choice whose key has gone falls back to Gemini.
    public static func resolved(in settings: any SettingsStore, qwenKey: String?) -> VoiceModel {
        let model = saved(in: settings)
        return model.isAvailable(qwenKey: qwenKey) ? model : defaultModel
    }

    public static func save(_ model: VoiceModel, in settings: any SettingsStore) {
        settings.set(model.rawValue, for: settingsKey)
    }
}
