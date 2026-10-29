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

/// Pure decision half of the dispatcher (F-09). Order: validate → driver-side window rewrite →
/// guards (unsupportedMedia → sunroofOnWindowTool → nearbyQuestionWhileNavigating →
/// vagueExitWhileNavigating → wordsUnclear → navigationNotRequested → speechOutputNotRequested → ambiguousReferent → repeatedInTurn) →
/// savedPlaceMissing. Keeps the repeat-in-turn record, so it lives inside AgentCore.
public struct ToolDispatcher: Sendable {
    /// Identical repeat-sensitive calls already dispatched, per driver turn (speech-onset epoch).
    private var dispatched: (epoch: Int, calls: Set<String>) = (0, [])

    public init() {}

    public mutating func decide(_ call: ToolCall, context: GuardContext,
                                clarify: (String) -> [String]? = { _ in nil }) -> DispatchDecision {
        if let code = ToolCatalog.validate(call) { return .refuse(Self.failure(code)) }
        var running = call
        if let window = ToolCallGuards.driverSideWindow(call, context), case .object(var args) = call.arguments {
            args["window"] = .string(window)
            running = ToolCall(id: call.id, name: call.name, arguments: .object(args))
        }
        let guards: [(ToolCall, GuardContext) -> ToolErrorCode?] = [
            ToolCallGuards.unsupportedMedia, ToolCallGuards.sunroofOnWindowTool,
            ToolCallGuards.nearbyQuestionWhileNavigating, ToolCallGuards.vagueExitWhileNavigating,
            ToolCallGuards.wordsUnclear, ToolCallGuards.navigationNotRequested,
            ToolCallGuards.speechOutputNotRequested,
        ]
        for check in guards {
            if let code = check(running, context) { return .refuse(Self.failure(code)) }
        }
        if let (code, options) = ToolCallGuards.ambiguousReferent(running, context, clarify: clarify) {
            return .refuse(Self.failure(code, data: ["options": .string(options.joined(separator: "还是"))]))
        }
        if repeatedInTurn(running, context) { return .refuse(Self.failure(.duplicateInTurn)) }
        if let code = ToolCallGuards.savedPlaceMissing(running, context) { return .refuse(Self.failure(code)) }
        return .execute(running)
    }

    /// Applied to an executor's result before it goes to the model.
    public func finish(_ call: ToolCall, _ result: ToolResult) -> ToolResult {
        ToolCallGuards.withPowerAdvice(call, result)
    }

    /// `repeatedInTurn`: the same repeat-sensitive call with the same arguments twice in one driver
    /// turn is a protocol retry. With no speech onset yet there is no turn, and nothing is dropped.
    private mutating func repeatedInTurn(_ call: ToolCall, _ c: GuardContext) -> Bool {
        guard ToolCatalog.spec(call.name)?.repeatSensitive == true, c.capabilityEpoch > 0 else { return false }
        if dispatched.epoch != c.capabilityEpoch { dispatched = (c.capabilityEpoch, []) }
        let key = call.name + "\u{0}" + Self.canonical(call.arguments)
        return !dispatched.calls.insert(key).inserted
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
