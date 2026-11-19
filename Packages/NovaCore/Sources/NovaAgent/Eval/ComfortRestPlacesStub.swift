import NovaKit
import NovaPorts
import NovaTools

/// F-09b §12 item 2 (T-031k): the comfort eval's `navigate_to`. No map, no route: it answers as the real tool does for
/// 「附近的X」 with several places, a list on the screen and one sentence from `next`, so the model hears the same.
public struct ComfortRestPlacesStub: ToolExecutor {
    public static let tool = "navigate_to"

    public init() {}

    public func execute(_ call: ToolCall) async -> ToolResult {
        .success([
            "status": "candidates_listed",
            "count": .int(3),
            "next": .string("屏幕上列出了3个地点。只说一句：找到3个地点，请说第几个。不要念列表。"),
        ])
    }
}
