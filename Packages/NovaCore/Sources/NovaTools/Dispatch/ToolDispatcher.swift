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
/// validate → repeatedInTurn → savedPlaceMissing (the F-15a start guard is withdrawn by T-040h: no route list). Keeps the repeat-in-turn record, so it
/// lives inside AgentCore. `exit_navigation_mode` is never held for a confirmation (F-05a §6, T-016e).
public struct ToolDispatcher: Sendable {
    /// Identical repeat-sensitive calls already dispatched, per driver turn (speech-onset epoch).
    private var dispatched: (epoch: Int, calls: Set<String>) = (0, [])
    /// F-15b §56 item 4 (T-040zi): `set_trip_plan` calls refused in the current driver request (speech-onset epoch),
    /// by canonical arguments, with their refusal; and the request each running `set_trip_plan` call was made in.
    private var refusedPlans: (epoch: Int, results: [String: ToolResult]) = (0, [:])
    private var planEpochs: [CallID: Int] = [:]

    public init() {}

    public mutating func decide(_ call: ToolCall, context: GuardContext) -> DispatchDecision {
        if call.name == "set_trip_plan" {
            // §56 item 4: the same refused plan is not run twice in one driver request; a changed call runs normally.
            if refusedPlans.epoch != context.turn { refusedPlans = (context.turn, [:]) }
            if let earlier = refusedPlans.results[Self.canonical(call.arguments)] { return .refuse(Self.repeated(earlier)) }
        }
        // F-15b §58 item 5 (T-040zk): a `set_trip_plan` with invalid fields runs into its executor, which refuses it
        // the same way (`refusal`) and shows the refusal on the work panel; the result is noted like PLAN_CHECK.
        if let code = ToolCatalog.validate(call), !(call.name == "set_trip_plan" && code == .invalidFields) {
            return .refuse(Self.refusal(call, code))
        }
        if repeatedInTurn(call, context) { return .refuse(Self.failure(.duplicateInTurn)) }
        if let code = ToolCallGuards.savedPlaceMissing(call, context) { return .refuse(Self.failure(code)) }
        if call.name == "set_trip_plan" { planEpochs[call.id] = context.turn }
        return .execute(call)
    }

    /// §56 item 4: a `set_trip_plan` result as it comes back. A `PLAN_CHECK` or `INVALID_FIELDS` refusal is kept for the
    /// driver request the call was made in (a result arriving after the driver spoke again starts nothing).
    public mutating func noteResult(_ call: ToolCall, _ result: ToolResult) {
        guard call.name == "set_trip_plan", let epoch = planEpochs.removeValue(forKey: call.id),
              result.code == .planCheck || result.code == .invalidFields, epoch == refusedPlans.epoch else { return }
        refusedPlans.results[Self.canonical(call.arguments)] = result
    }

    /// §56 item 4: `REPEATED_FAILURE` with the earlier refusal's `problems` (top level, or `facts.problems` of
    /// `PLAN_CHECK`) and §56's `next`; `refused_code` is the earlier code (the record's `trip repeat-blocked`).
    public static func repeated(_ earlier: ToolResult) -> ToolResult {
        let problems = earlier.data["problems"] ?? earlier.data["facts"]?["problems"] ?? .array([])
        let code = earlier.code ?? .invalidFields
        return ToolResult(ok: false, code: .repeatedFailure,
                          data: ["problems": problems, "refused_code": .string(code.rawValue), "changed": false,
                                 "next": .string(repeatedNext)], advice: nil)
    }

    /// §56 item 4: the `next` of `REPEATED_FAILURE`, exactly as §56 gives it.
    public static let repeatedNext = "这份行程刚才已经被拒绝了，原因在 problems 里。按它改，改不了就告诉司机行程没改成和原因，不要再传同样的内容。"

    /// The refusal of a call `ToolCatalog.validate` stopped. F-15b §56 item 3 (T-040zi): `INVALID_FIELDS` of
    /// `set_trip_plan` carries `problems` (one line each) and §56's `next`; it is never an empty `{}`.
    public static func refusal(_ call: ToolCall, _ code: ToolErrorCode) -> ToolResult {
        guard code == .invalidFields, call.name == "set_trip_plan", case .object(let a) = call.arguments else { return failure(code) }
        let lines = ToolCatalog.tripPlanProblems(a)
        return ToolResult(ok: false, code: .invalidFields,
                          data: ["problems": .array(lines.map(JSONValue.string)), "changed": false,
                                 "next": .string(ToolCatalog.tripProblemsNext)], advice: nil)
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
        // F-09b §13 item 6 (T-031o): the caller's data are the facts (and stay where readers expect them).
        ToolFailureAdvice.reply(code, facts: data, extra: data)
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
