/// F-07 §14 item 2: the voices that work on the owner's Singapore host, in picker order.
public struct QwenVoiceOption: Sendable, Hashable {
    public let id: String
    public let label: String

    public static let all: [QwenVoiceOption] = [
        QwenVoiceOption(id: "longanhuan_v3.1", label: "龙安欢"),
        QwenVoiceOption(id: "longanlingxin_v3.1", label: "龙安灵心"),
        QwenVoiceOption(id: "longanfengyue_v3.1", label: "龙安风悦"),
    ]
    public static let defaultID = "longanhuan_v3.1"
}
