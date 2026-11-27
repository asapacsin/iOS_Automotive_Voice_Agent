import Foundation
import Synchronization
import NovaKit

/// F-18 §32 (T-046u): every paid call is asked here before it is sent, and reported here after it returns.
/// Pure logic: no networking. Sources (copied, not invented): LiteLLM Agent Iteration Budgets (check before the call),
/// AWS Agentic AI Lens AGENTCOST07-BP01, OpenRouter loop guide (block the third identical call), dev.to tool-call
/// budgets (one shared cap over all tools).
public enum PaidRoute: String, Sendable, Hashable, CaseIterable {
    case qwenLive = "qwen.live"
    case qwenPicker = "qwen.picker"
    case qwenGround = "qwen.ground"
    /// F-18 §36 (T-046y): the trip planner and the §35 events loop, now through `QwenFallback`.
    case qwenPlanner = "qwen.planner"
    case qwenEvents = "qwen.events"
    case geminiVision = "gemini.vision"
    case glmVision = "glm.vision"
    // F-07 §18 item 2 (T-020e): `qwen.tts` and its uncapped exception are removed with the 千问 TTS source.
}

/// §32 item 4: `reason=` of `LIVE_INFO_UNAVAILABLE`.
public enum BudgetReason: String, Sendable, Hashable {
    case budget, `repeat`, quota
}

public enum BudgetDecision: Sendable, Hashable {
    case allow
    case refuse(BudgetReason)
}

/// Thrown by a client whose call the budget refused. Nothing was sent.
public struct BudgetRefused: Error, Sendable, Hashable {
    public let reason: BudgetReason
    public init(_ reason: BudgetReason) { self.reason = reason }
}

/// §32 item 1, marked `Tuning` (F-09b §15 counts them in the agent setup).
public struct BudgetLimits: Sendable, Hashable {
    public var perTurn: Int
    public var perRoutePerTurn: Int
    public var perSession: Int
    public var perDayCalls: Int
    public var perDayTokens: Int
    /// §32 item 2: a key already sent `repeatMax` times within `repeatWindow` is refused.
    public var repeatMax: Int
    public var repeatWindow: NovaDuration
    /// F-18 §33 item 1 (T-046v): off, `ask` checks no limit (the numbers are not read); calls are still counted.
    public var enforce: Bool

    // Tuning
    public static let standard = BudgetLimits(perTurn: 3, perRoutePerTurn: 2, perSession: 40, perDayCalls: 300,
                                              perDayTokens: 300_000, repeatMax: 2, repeatWindow: .minutes(10), enforce: true)
    /// §33 item 3: the app's limits. Normal use has no call limit; only the quota breaker (§32 item 3) refuses.
    public static let unlimited = BudgetLimits(perTurn: 0, perRoutePerTurn: 0, perSession: 0, perDayCalls: 0,
                                               perDayTokens: 0, repeatMax: 0, repeatWindow: .minutes(10), enforce: false)

    public init(perTurn: Int, perRoutePerTurn: Int, perSession: Int, perDayCalls: Int, perDayTokens: Int,
                repeatMax: Int, repeatWindow: NovaDuration, enforce: Bool = true) {
        self.enforce = enforce
        self.perTurn = perTurn
        self.perRoutePerTurn = perRoutePerTurn
        self.perSession = perSession
        self.perDayCalls = perDayCalls
        self.perDayTokens = perDayTokens
        self.repeatMax = repeatMax
        self.repeatWindow = repeatWindow
    }
}

/// The day counter, kept across app restarts (§32 item 1). `date` is the phone's local `yyyy-MM-dd`.
public struct BudgetDay: Sendable, Hashable, Codable {
    public var date: String
    public var calls: Int
    public var tokens: Int
    /// §32 item 3: models that answered "quota used up" today.
    public var quotaModels: [String]

    public init(date: String, calls: Int = 0, tokens: Int = 0, quotaModels: [String] = []) {
        self.date = date
        self.calls = calls
        self.tokens = tokens
        self.quotaModels = quotaModels
    }
}

/// §32 item 1: the port the app's adapter implements (`UserDefaults`).
public protocol BudgetStore: Sendable {
    func load() -> BudgetDay?
    func save(_ day: BudgetDay)
}

/// A store kept in memory only (tests, and before the app sets its own).
public final class MemoryBudgetStore: BudgetStore {
    private let day = Mutex<BudgetDay?>(nil)
    public init(_ initial: BudgetDay? = nil) { day.withLock { $0 = initial } }
    public func load() -> BudgetDay? { day.withLock { $0 } }
    public func save(_ d: BudgetDay) { day.withLock { $0 = d } }
}

public final class CallBudget: Sendable {
    /// The app's one budget; the app sets its store and log at start. F-18 §33 item 3: not capped (`.unlimited`).
    public static let shared = CallBudget(limits: .unlimited)

    private struct State {
        var store: any BudgetStore
        var log: (@Sendable (String) -> Void)?
        var turnCalls = 0
        var turnByRoute: [PaidRoute: Int] = [:]
        /// §32 item 4: after a refusal the same turn makes no further paid call.
        var turnClosed = false
        var sessionCalls = 0
        var sent: [String: [NovaInstant]] = [:]
        var day: BudgetDay?
    }

    public let limits: BudgetLimits
    private let clock: any NovaClock
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    private let state: Mutex<State>

    public init(limits: BudgetLimits = .standard, store: any BudgetStore = MemoryBudgetStore(),
                clock: any NovaClock = SystemClock(), now: @escaping @Sendable () -> Date = { Date() },
                zone: @escaping @Sendable () -> TimeZone = { .current }, log: (@Sendable (String) -> Void)? = nil) {
        self.limits = limits
        self.clock = clock
        self.now = now
        self.zone = zone
        state = Mutex(State(store: store, log: log))
    }

    public func setStore(_ store: any BudgetStore) { state.withLock { $0.store = store; $0.day = nil } }
    public func setLog(_ log: @escaping @Sendable (String) -> Void) { state.withLock { $0.log = log } }

    /// A new driver turn (her final words arrived).
    public func newTurn() {
        state.withLock { s in
            s.turnCalls = 0
            s.turnByRoute = [:]
            s.turnClosed = false
        }
    }

    /// A new voice session: turn and session counters and the repeat history start over; the day stays.
    public func newSession() {
        newTurn()
        state.withLock { s in
            s.sessionCalls = 0
            s.sent = [:]
        }
    }

    /// §32 item 2: route + model + the normalised request (text trimmed and lower-cased, coordinates to 3 decimals).
    public static func key(_ route: PaidRoute, model: String, text: String, coordinates: [Double] = []) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let c = coordinates.map { String(format: "%.3f", $0) }.joined(separator: ",")
        return "\(route.rawValue)|\(model)|\(t)|\(c)"
    }

    /// Asked before the call. `.allow` counts the call at once (so parallel calls cannot pass a limit together).
    public func ask(_ route: PaidRoute, model: String, key: String) -> BudgetDecision {
        let at = clock.now
        let today = Self.date(now(), zone())
        let (decision, line): (BudgetDecision, String?) = state.withLock { s in
            var day = Self.today(&s, today)
            func refuse(_ r: BudgetReason) -> (BudgetDecision, String?) {
                // A quota refusal leaves the turn open: the route's backup model is tried once (item 3).
                if r != .quota { s.turnClosed = true }
                return (.refuse(r), "paid route=\(route.rawValue) model=\(model) refused=\(r.rawValue)")
            }
            if day.quotaModels.contains(model) { return refuse(.quota) }
            if limits.enforce {
                if s.turnClosed || s.turnCalls >= limits.perTurn || s.turnByRoute[route, default: 0] >= limits.perRoutePerTurn
                    || s.sessionCalls >= limits.perSession || day.calls >= limits.perDayCalls
                    || day.tokens >= limits.perDayTokens {
                    return refuse(.budget)
                }
                let recent = s.sent[key, default: []].filter { at - $0 < limits.repeatWindow }
                if recent.count >= limits.repeatMax { return refuse(.repeat) }
                s.sent[key] = recent + [at]
            }
            s.turnCalls += 1
            s.turnByRoute[route, default: 0] += 1
            s.sessionCalls += 1
            day.calls += 1
            s.day = day
            s.store.save(day)
            return (.allow, nil)
        }
        if let line { emit(line) }
        return decision
    }

    /// Reported after an allowed call returned (or failed). `quotaError` opens the model's breaker for the day.
    public func done(_ route: PaidRoute, model: String, ok: Bool, tokens: Int?, quotaError: Bool = false) {
        let today = Self.date(now(), zone())
        let line: String = state.withLock { s in
            var day = Self.today(&s, today)
            day.tokens += max(0, tokens ?? 0)
            if quotaError, !day.quotaModels.contains(model) { day.quotaModels.append(model) }
            s.day = day
            s.store.save(day)
            return "paid route=\(route.rawValue) model=\(model) ok=\(ok ? "yes" : "no") tokens=\(tokens.map(String.init) ?? "-") "
                + "turnN=\(s.turnCalls) sessionN=\(s.sessionCalls) dayN=\(day.calls) dayTokens=\(day.tokens)"
                + (quotaError ? " quota=yes" : "")
        }
        emit(line)
    }

    /// Today's counter; a stored counter of another date starts over (local midnight).
    private static func today(_ s: inout State, _ date: String) -> BudgetDay {
        if let d = s.day, d.date == date { return d }
        if let d = s.store.load(), d.date == date { s.day = d; return d }
        let d = BudgetDay(date: date)
        s.day = d
        return d
    }

    private func emit(_ line: String) { state.withLock { $0.log }?(line) }

    static func date(_ d: Date, _ zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The tokens a reply reports: the last `total_tokens` (DashScope, Zhipu) or `totalTokenCount` (Gemini) in it.
    public static func reportedTokens(_ body: Data) -> Int? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        var found: Int?
        for name in ["\"total_tokens\"", "\"totalTokenCount\""] {
            var rest = text[...]
            while let r = rest.range(of: name) {
                rest = rest[r.upperBound...]
                let digits = rest.drop { $0 == ":" || $0 == " " }.prefix { $0.isNumber }
                if let n = Int(digits) { found = n }
            }
        }
        return found
    }
}

/// §32 item 3: which errors are "quota used up" (the breaker), as the vendors publish them (2026-11-20, copied into
/// F-18 §32 item 3). A plain rate limit is not one.
/// - DashScope (alibabacloud.com/help/en/model-studio/error-code): `AllocationQuota.FreeTierOnly` (403),
///   `BudgetLimitExceeded` (429), and `Throttling.AllocationQuota` (429) only with "Free allocated quota exceeded"
///   (the same code also means a TPM limit).
/// - Gemini (aistudio.google.com/docs/api-errors): 429 `quota_exceeded` ("You have exceeded your daily quota").
///   Seen live on generativelanguage.googleapis.com (2026-11-20): 429 RESOURCE_EXHAUSTED "You exceeded your current
///   quota" with a `QuotaFailure` violation whose `quotaId` names the window; only a per-day window is used up for
///   the day (a per-minute one is a rate limit).
public enum QuotaError {
    public static func dashScope(status: Int, code: String?, message: String?) -> Bool {
        guard status == 403 || status == 429, let code else { return false }
        switch code {
        case "AllocationQuota.FreeTierOnly", "BudgetLimitExceeded": return true
        case "Throttling.AllocationQuota": return (message ?? "").lowercased().contains("free allocated quota")
        default: return false
        }
    }

    public static func gemini(status: Int, body: Data) -> Bool {
        guard status == 429, let text = String(data: body, encoding: .utf8) else { return false }
        if text.contains("quota_exceeded") || text.lowercased().contains("exceeded your daily quota") { return true }
        return text.range(of: #""quotaId"\s*:\s*"[^"]*PerDay"#, options: .regularExpression) != nil
    }
}
