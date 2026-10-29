import NovaKit
import NovaPorts

/// What happens to one call (`AndroidToolDispatcher.dispatch`).
public enum DispatchDecision: Sendable, Hashable {
    /// Refused before running; this result goes straight back to the model.
    case refuse(ToolResult)
    /// Run this call (possibly rewritten, e.g. `window=driver`) on its executor.
    case execute(ToolCall)
}

/// Runs one tool. Never throws into the session: every failure is `ok=false` with a code.
public protocol ToolExecutor: Sendable {
    func execute(_ call: ToolCall) async -> ToolResult
}

/// M1 stand-in for tools without an iOS executor yet (ios-architecture §8): one honest refusal (I-2).
public struct NotYetExecutor: ToolExecutor {
    public init() {}
    public func execute(_ call: ToolCall) async -> ToolResult {
        ToolDispatcher.failure(.notAvailableOnIOSYet)
    }
}

/// Pure decision half of the dispatcher (F-09, revised by F-05a §6: no guard reads the transcript). Order:
/// validate → navigationNotRequested → confirmExit → repeatedInTurn → savedPlaceMissing. Keeps the repeat-in-turn
/// record and the pending exit question, so it lives inside AgentCore.
public struct ToolDispatcher: Sendable {
    /// While guidance runs, a second `exit_navigation_mode` within this long, in a later driver turn, ends it.
    public static let exitConfirmWindow = NovaDuration.seconds(15)

    /// Identical repeat-sensitive calls already dispatched, per driver turn (speech-onset epoch).
    private var dispatched: (epoch: Int, calls: Set<String>) = (0, [])
    /// The first `exit_navigation_mode` while guiding: she asked 「要结束导航吗？」 in this closed turn at this time.
    private var exitAsked: (turn: Int, at: NovaInstant)?

    public init() {}

    public mutating func decide(_ call: ToolCall, context: GuardContext) -> DispatchDecision {
        if let code = ToolCatalog.validate(call) { return .refuse(Self.failure(code)) }
        if let code = ToolCallGuards.navigationNotRequested(call, context) { return .refuse(Self.failure(code)) }
        if confirmExit(call, context) { return .refuse(Self.failure(.confirmRequired)) }
        if repeatedInTurn(call, context) { return .refuse(Self.failure(.duplicateInTurn)) }
        if let code = ToolCallGuards.savedPlaceMissing(call, context) { return .refuse(Self.failure(code)) }
        return .execute(call)
    }

    /// F-05a §6 (replaces the vague-exit word guard): while guidance runs with no list open, the first
    /// `exit_navigation_mode` is answered with `CONFIRM_REQUIRED` (she asks 「要结束导航吗？」); a second call in a
    /// later driver turn within `exitConfirmWindow` ends it. Taps are the request (I-6). True = refuse.
    private mutating func confirmExit(_ call: ToolCall, _ c: GuardContext) -> Bool {
        if !c.guidanceRunning { exitAsked = nil }
        guard call.name == "exit_navigation_mode", c.guidanceRunning, !c.listOpen, !c.fromTap else { return false }
        if let asked = exitAsked, c.closedTurns > asked.turn, c.now - asked.at <= Self.exitConfirmWindow {
            exitAsked = nil
            return false
        }
        exitAsked = (c.closedTurns, c.now)
        return true
    }

    /// `repeatedInTurn`: the same repeat-sensitive call with the same arguments twice in one driver
    /// turn is a protocol retry. With no speech onset yet there is no turn, and nothing is dropped.
    private mutating func repeatedInTurn(_ call: ToolCall, _ c: GuardContext) -> Bool {
        guard ToolCatalog.spec(call.name)?.repeatSensitive == true, c.turn > 0 else { return false }
        if dispatched.epoch != c.turn { dispatched = (c.turn, []) }
        let key = call.name + "\u{0}" + Self.canonical(call.arguments)
        return !dispatched.calls.insert(key).inserted
    }

    /// Applied to an executor's result before it goes to the model.
    public func finish(_ call: ToolCall, _ result: ToolResult) -> ToolResult {
        ToolCallGuards.withPowerAdvice(call, result)
    }

    public static func failure(_ code: ToolErrorCode, data: [String: JSONValue] = [:]) -> ToolResult {
        .failure(code, advice: ToolFailureAdvice.forCode(code), data: data)
    }

    private static func canonical(_ value: JSONValue) -> String {
        (try? JSONValue.canonicalEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

extension ToolResult {
    /// The Android `functionResponse` body: `{"ok", "tool", "error"?, "next"?, ...data}`.
    public func wireObject(tool: String) -> JSONValue {
        var object = data
        object["ok"] = .bool(ok)
        object["tool"] = .string(tool)
        if let code { object["error"] = .string(code.rawValue) }
        if let advice { object["next"] = .string(advice) }
        return .object(object)
    }
}
