import Foundation
import NovaKit
import NovaPorts
import NovaTools
import Synchronization

/// F-15b §65 (T-040zr): a trip saved in an earlier conversation is not in her context note until it is used in this one.
/// Off at the start of each new conversation; on from the first `plan_trip`/`set_trip_plan` result, the first trip tool
/// that reads the saved plan (`trip_next`, `trip_plans` open, `exit_navigation_mode` on the trip screen, any result with
/// `plan_kept`) or the first touch on the trip screen or a card, until the conversation ends. Code only: no prompt text.
/// The plan itself is never deleted; trip tools read it directly whether the line is on or off.
public final class TripContextGate: Sendable {
    public enum Reason: Sendable, Hashable {
        case planTrip, setTripPlan, tool(String), touch

        /// §65 item 4: the `reason=` value.
        public var text: String {
            switch self {
            case .planTrip: "plan_trip"
            case .setTripPlan: "set_trip_plan"
            case .tool(let name): "tool:\(name)"
            case .touch: "touch"
            }
        }
    }

    private let on = Mutex(false)

    public init() {}

    public var isOn: Bool { on.withLock { $0 } }

    /// §65 item 1: a new conversation starts with the line off.
    public func reset() { on.withLock { $0 = false } }

    /// §65 item 2: turns the line on; returns the §65 item 4 record line only when it was off.
    @discardableResult
    public func turnOn(_ reason: Reason) -> String? {
        on.withLock { value -> String? in
            guard !value else { return nil }
            value = true
            return Self.line(reason)
        }
    }

    /// §65 item 4: `trip context on reason=<plan_trip|set_trip_plan|tool:<name>|touch>`.
    public static func line(_ reason: Reason) -> String { "trip context on reason=\(reason.text)" }

    /// §65 items 1–2: the context note's trip line, nil while off (the snapshot then has no `trip` field).
    public func noteLine(_ plan: TripPlan) -> String? { isOn ? TripPlanJSON.noteLine(plan) : nil }

    /// §65 item 2: the tool call that uses the trip, or nil. `onTripScreen`: the trip screen was shown when the call came.
    public static func reason(_ call: ToolCall, _ result: ToolResult, onTripScreen: Bool) -> Reason? {
        switch call.name {
        case "plan_trip": return .planTrip
        case "set_trip_plan": return .setTripPlan
        case "trip_next": return .tool("trip_next")
        case "trip_plans" where call.arguments["action"]?.stringValue == "open": return .tool("trip_plans")
        case "exit_navigation_mode" where onTripScreen: return .tool("exit_navigation_mode")
        default: break
        }
        if result.data["plan_kept"] != nil || result.data["facts"]?["plan_kept"] != nil { return .tool(call.name) }
        return nil
    }
}

/// F-15b §65 item 2: wraps a tool executor; a result that uses the trip turns the trip line on (and writes its record line).
public struct TripContextExecutor: ToolExecutor {
    let inner: any ToolExecutor
    let gate: TripContextGate
    let onTripScreen: @Sendable () async -> Bool
    let onLine: @Sendable (String) -> Void

    public init(_ inner: any ToolExecutor, gate: TripContextGate, onTripScreen: @escaping @Sendable () async -> Bool,
                onLine: @escaping @Sendable (String) -> Void) {
        self.inner = inner
        self.gate = gate
        self.onTripScreen = onTripScreen
        self.onLine = onLine
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        // The screen before the call: `exit_navigation_mode` closes the trip screen it reads from.
        let screen = call.name == "exit_navigation_mode" ? await onTripScreen() : false
        let result = await inner.execute(call)
        if let reason = TripContextGate.reason(call, result, onTripScreen: screen), let line = gate.turnOn(reason) { onLine(line) }
        return result
    }
}
