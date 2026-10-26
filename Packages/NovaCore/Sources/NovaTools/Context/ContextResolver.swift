import NovaKit
import NovaPorts

/// What a relative cabin change acts on (F-10 referents).
public enum ContextDimension: String, Sendable, Hashable, CaseIterable {
    case temperature, fan, seat, window

    /// The word 小诺 uses when she asks back (「是座椅还是温度？」).
    public var spokenName: String {
        switch self {
        case .temperature: "温度"
        case .fan: "风量"
        case .seat: "座椅"
        case .window: "车窗"
        }
    }

    /// Words that name this dimension in a driver line. 冷/热/凉/暖 can only mean temperature.
    var words: [String] {
        switch self {
        case .temperature: ["温度", "空调", "度", "冷", "热", "凉", "暖"]
        case .fan: ["风", "风量", "风速"]
        case .seat: ["座椅", "座位", "椅子", "坐"]
        case .window: ["窗"]
        }
    }

    /// The dimension a relative tool call changes, or nil for anything else.
    public static func of(_ call: ToolCall) -> ContextDimension? {
        let action = call.arguments["action"]?.stringValue
        switch (call.name, action) {
        case ("control_climate", "adjust_temperature"), ("control_climate", "set_temperature"): return .temperature
        case ("control_climate", "adjust_fan"), ("control_climate", "set_fan"): return .fan
        case ("control_seat", "adjust_height"), ("control_seat", "set_height"): return .seat
        case ("control_window", "adjust"), ("control_window", "set"), ("control_window", "open"),
             ("control_window", "close"):
            return .window
        default: return nil
        }
    }
}

/// F-10 driver context (`A/voice/DriverContext.kt`, `ContextResolver.kt`): which cabin dimensions the
/// driver really changed in the last 180 s, and whether a vague follow-up (「再低一点」, misheard
/// 「第一点」) names one of them. Pure; AgentCore owns it.
public struct DriverContext: Sendable, Hashable {
    /// Referents older than this are forgotten (F-10 §3).
    public static let referentLifetime = NovaDuration.seconds(180)

    /// Last successful change per dimension.
    private var changed: [ContextDimension: NovaInstant] = [:]

    public init() {}

    /// Records a finished call; only an ok=true result is a referent.
    public mutating func record(_ call: ToolCall, ok: Bool, at now: NovaInstant) {
        guard ok, let dimension = ContextDimension.of(call) else { return }
        changed[dimension] = now
    }

    /// Dimensions changed within the lifetime, most recent first.
    public func referents(at now: NovaInstant) -> [ContextDimension] {
        changed.filter { now - $0.value < Self.referentLifetime }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    /// The options to ask about, or nil when the call may run. A line that names a dimension is never
    /// ambiguous; otherwise two or more live referents are (F-10 §10 row 1), one is not (row 2), and none
    /// asks nothing (row 3).
    public func clarify(_ requestText: String, at now: NovaInstant) -> [String]? {
        let said = TranscriptText.normalize(requestText)
        guard !ContextDimension.allCases.contains(where: { $0.words.contains(where: said.contains) }) else { return nil }
        let live = referents(at: now)
        guard live.count >= 2 else { return nil }
        return live.prefix(2).map(\.spokenName)
    }
}
