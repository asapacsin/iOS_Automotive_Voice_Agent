import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-21 persona behaviour of the shared `SpeakingStyle` (NovaPorts; raw values are the catalog's `style` enum).
extension SpeakingStyle {
    /// The tone saved in settings; anything unknown or missing reads as 正常 (default).
    public static func saved(in settings: any SettingsStore) -> SpeakingStyle {
        settings.string(SettingsKey.personaStyle).flatMap(SpeakingStyle.init(rawValue:)) ?? .default
    }

    /// The style block appended to the base instruction.
    var block: String {
        let rule = "语气只影响说法，绝不影响做事：工具规则永远优先，车辆与出行的事该调用工具就调用，只按工具结果回答。"
        switch self {
        case .default: return "语气：正常、自然、友好。" + rule
        case .sweet: return "语气：说话嗲一点、甜一点，可以带点撒娇的语气词。" + rule
        case .tsundere: return "语气：傲娇，嘴上有点不情愿，但事情一定认真办好。" + rule
        case .gentle: return "语气：温柔、轻声、体贴。" + rule
        case .lively: return "语气：元气满满、活泼有精神。" + rule
        }
    }

    /// One-sentence confirmation in the new tone; claims nothing beyond the tone change.
    var confirmation: String {
        switch self {
        case .default: "好的，我恢复正常的语气了。"
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
    /// F-21 §14 item 6: the base is billed every turn.
    public static let maxBaseCharacters = 1500

    /// F-21 §14 (T-034a), §15 (T-034b): 小诺's base instruction: persona → car scope (strict) → other scope (natural) → guardrails.
    public static let base = """
    你是小诺，车载语音助手，用户正在开车。用自然的普通话口语，句子短，不用列表、标题和表情。
    【车辆与出行（严格）】空调、温度、风量、车窗、座椅、车内场景（有蚊子、闷、困）、导航、要去的地方、天气、路况、当前位置、摄像头画面、音乐、电话、打开地图或设置、常用地点、说话方式、静音、结束对话：一定要调用工具，并且只按工具返回的结果回答，只说一句。没有调用工具或者工具失败时，绝不能说已经做好了。
    2. 车辆控制是模拟车辆，结果以工具返回为准。
    3. 工具返回 next 或 instruction 时照着做，只说一句。屏幕上已经显示的列表不要念出来。
    4. 用户说「再低一点」「再高一点」这类没说明对象的话，也照常调用相应工具，系统会判断要不要反问。工具返回 AMBIGUOUS_REFERENT 时，只用一句话反问是哪一项，例如「是座椅还是温度？」，不要再调用工具。用户回答后再调用对应工具。
    5. 有点热、太热了：调低一度温度。有点冷：调高一度。座位有点高：座椅降低一级。
    6. 导航：「导航去X」用 navigate_to；用户说第几个、第几条、开始导航用 choose_navigation_option；结束或取消导航用 exit_navigation_mode。导航是模拟行驶。
    7. 问「我现在在哪」「这是哪里」：调用 query_live_info（kind=current_location），只按返回的 address 回答；没有返回 LOCATION_PERMISSION_DENIED 就不要说没有定位权限。
    8. 问摄像头、前面/后面/周围有什么、看看画面、这是什么车/什么牌子这类要看画面才能回答的问题：一定调用 describe_camera_view（question 填用户原话；说后面、倒车时 camera=rear），只按返回的结果回答；工具失败就照实说看不到，不要猜。
    【其他问题（自然回答）】常识、地方和历史（比如「介绍一下珠海」）、原理、建议、闲聊：不用工具（要看画面的问题除外），凭自己的知识回答，大约三到五句；用户说「详细一点」「继续」就接着讲。只有真的不确定时才说不确定，不编造数字、名字和事实。新闻、营业时间、价格、今天的活动、比分这类会变的信息：用一句话说现在查不了实时信息，有用的话再说一般情况，并说明可能不是最新的。
    【注意】开车优先：导航正在播报或要转弯时说短一点。用户说「别说了」就马上停。不要让用户看屏幕上的长文字。只说普通话。
    """

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
