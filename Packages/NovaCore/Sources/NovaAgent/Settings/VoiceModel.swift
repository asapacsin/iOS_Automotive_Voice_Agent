import NovaKit
import NovaPorts

/// F-05 §15 item 1 (T-016q): 设置 「语音模型」, the realtime model her session talks to. Stored on the phone; it takes
/// effect at the next connect. Gemini is the default; a Qwen choice needs the 百炼 key saved for search (F-18 §40).
/// Pure.
public enum VoiceModel: String, Sendable, Hashable, CaseIterable {
    case geminiLive = "gemini-3.8-live"
    case qwenFlash = "qwen-audio-3.1-realtime-flash"
    case qwenPlus = "qwen-audio-3.1-realtime-plus"

    public static let settingsKey = SettingsKey.voiceModel
    public static let `default` = VoiceModel.geminiLive
    /// Item 1: the row says a change applies from the next connect.
    public static let nextConnectNote = "下次连接时生效"
    /// Item 1: why a Qwen choice is shown disabled.
    public static let qwenKeyMissingMessage = "先在设置里填百炼 key"

    /// The 设置 label.
    public var label: String {
        switch self {
        case .geminiLive: "Gemini 3.8 Live"
        case .qwenFlash: "Qwen Audio 3.1 Flash"
        case .qwenPlus: "Qwen Audio 3.1 Plus"
        }
    }

    public var isQwen: Bool { self != .geminiLive }

    /// The model id sent to the provider and written as the record header's `voiceModel` (item 6).
    public var modelID: String { rawValue }

    /// Item 1 (T-016r): Gemini always; a Qwen choice only with the 百炼 key saved (no API Host is used or needed).
    public func isAvailable(qwenKeySaved: Bool) -> Bool {
        !isQwen || qwenKeySaved
    }

    /// The disabled row's text, or nil when the choice can be picked.
    public func disabledReason(qwenKeySaved: Bool) -> String? {
        isAvailable(qwenKeySaved: qwenKeySaved) ? nil : Self.qwenKeyMissingMessage
    }

    /// The saved choice; unset or unknown reads as the default.
    public static func saved(in settings: any SettingsStore) -> VoiceModel {
        settings.string(settingsKey).flatMap(VoiceModel.init(rawValue:)) ?? .default
    }

    /// The model a session connects with: the saved choice, or Gemini when a saved Qwen choice is no longer available
    /// (its key was removed after it was picked).
    public static func effective(in settings: any SettingsStore, qwenKeySaved: Bool) -> VoiceModel {
        let choice = saved(in: settings)
        return choice.isAvailable(qwenKeySaved: qwenKeySaved) ? choice : .default
    }
}
