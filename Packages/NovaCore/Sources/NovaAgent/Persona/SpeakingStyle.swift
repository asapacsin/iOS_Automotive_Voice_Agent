import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-21 小诺's speaking tone (`A/SpeakingStyle.kt`). Raw values are the catalog's `style` enum.
public enum SpeakingStyle: String, Sendable, Hashable, CaseIterable {
    case normal = "default"
    case sweet
    case tsundere
    case gentle
    case lively

    /// The tone saved in settings; anything unknown or missing reads as 正常 (default).
    public static func saved(in settings: any SettingsStore) -> SpeakingStyle {
        settings.string(SettingsKey.personaStyle).flatMap(SpeakingStyle.init(rawValue:)) ?? .normal
    }

    /// The style block appended to the base instruction.
    var block: String {
        let rule = "语气只影响说法，绝不影响做事：工具规则永远优先，该调用工具就调用，只按工具结果回答。"
        switch self {
        case .normal: return "语气：正常、自然、友好。" + rule
        case .sweet: return "语气：说话嗲一点、甜一点，可以带点撒娇的语气词。" + rule
        case .tsundere: return "语气：傲娇，嘴上有点不情愿，但事情一定认真办好。" + rule
        case .gentle: return "语气：温柔、轻声、体贴。" + rule
        case .lively: return "语气：元气满满、活泼有精神。" + rule
        }
    }

    /// One-sentence confirmation in the new tone; claims nothing beyond the tone change.
    var confirmation: String {
        switch self {
        case .normal: "好的，我恢复正常的语气了。"
        case .sweet: "好呀，人家以后就甜甜地跟你说话啦。"
        case .tsundere: "哼，换就换，才不是因为你想听呢。"
        case .gentle: "好的，我会温柔地跟你说话。"
        case .lively: "好嘞，元气满满模式开启啦！"
        }
    }
}

/// The session's system instruction: the base persona plus the style block (≤ 4000 characters).
public enum PersonaInstruction {
    public static let maxCharacters = 4000

    /// Only the style block is truncated; the base (with its tool rules) is never cut.
    public static func build(base: String, style: SpeakingStyle) -> String {
        let separator = "\n"
        let room = maxCharacters - base.count - separator.count
        guard room > 0 else { return base }
        return base + separator + String(style.block.prefix(room))
    }
}

/// `set_speaking_style` (`A/tools/SpeechDomain.kt:13`): saves the tone, which the next session start
/// reads into the system instruction. Lives in NovaAgent because `SettingsKey` does.
public struct SpeakingStyleHandler: ToolExecutor {
    public static let tool = "set_speaking_style"
    private let settings: any SettingsStore

    public init(settings: any SettingsStore) { self.settings = settings }

    public func execute(_ call: ToolCall) async -> ToolResult {
        guard let raw = call.arguments["style"]?.stringValue, let style = SpeakingStyle(rawValue: raw) else {
            return ToolDispatcher.failure(.styleNotAllowed)
        }
        settings.set(style.rawValue, for: SettingsKey.personaStyle)
        // The catalog description tells the model to answer from `instruction`; `next` matches the other tools.
        let reply = "用新语气简短回应，例如：" + style.confirmation
        return .success(["style": .string(style.rawValue), "instruction": .string(reply), "next": .string(reply)])
    }
}
