import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import NovaKit
import NovaPorts

/// F-15b §50 item 10 (T-040x), F-18 §36 (T-046y, owner 2026-11-24): a job's ordered model list (`QwenRoute.chain`)
/// when a model's budget is used up. Model Studio counts free quota and rate limits per model for the whole account,
/// so another model (not another key) gives more room; gateways do the same (LiteLLM fallbacks and cooldowns).
/// - Moves only for an HTTP 429, a 403 whose error `code` contains `Quota`, or a published quota code (F-18 §32
///   item 3, `QuotaError.dashScope`). Bodies are read whole and a non-200 status carries no answer, so a move never
///   follows a streamed answer (a 200 with an error chunk never moves). Any other error is the job's failure.
/// - Each entry at most once per call, in list order; later entries get only what is left of `QwenRoute.budget`.
/// - §36 item 3: a quota answer marks the model used up for 24 h (`QwenRoute.usedUpFor`) or until the app restarts;
///   marked models are not called. A 429 skips the model for `QwenRoute.cooldown` (60 s): cooled entries go after the
///   others, so a one-model job still tries again. Every entry marked: the call fails at once with no request.
/// - Record: `qwen fallback job=<job> from=<model> to=<model> reason=quota|rate`, and `qwen exhausted model=<model>`
///   once when a model is marked (I-8: enums and model names only).
public final class QwenFallback: Sendable {
    public enum Reason: String, Sendable, Hashable {
        case rateLimit = "rate"
        case quota
    }

    /// One process-wide state, so every client sees the same marks (all keys share the model's limits).
    /// F-18 §32: the app attaches `CallBudget.shared` at start (`setBudget`); tests that use it get none.
    public static let shared = QwenFallback()

    private struct State {
        var cooledUntil: [String: NovaInstant] = [:]
        var usedUpUntil: [String: NovaInstant] = [:]
        var log: (@Sendable (String) -> Void)?
        var budget: CallBudget?
    }

    private let clock: any NovaClock
    private let state: Mutex<State>
    /// F-18 §32 (T-046u): asked before every attempt; nil only in tests that do not test the budget.
    private var budget: CallBudget? { state.withLock { $0.budget } }

    public init(clock: any NovaClock = SystemClock(), budget: CallBudget? = nil, log: (@Sendable (String) -> Void)? = nil) {
        self.clock = clock
        state = Mutex(State(log: log, budget: budget))
    }

    public func setBudget(_ budget: CallBudget) { state.withLock { $0.budget = budget } }

    /// The app's log sink for the fallback lines.
    public func setLog(_ log: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.log = log }
    }

    /// Only a 429, or a 403 whose error code contains `Quota`. Anything else (401, `InvalidApiKey`, 5xx): nil.
    public static func reason(status: Int, body: Data) -> Reason? {
        // F-18 §32 item 3: the published quota codes (a 429 among them) are quota, not a rate limit.
        if quotaError(status: status, body: body) { return .quota }
        if status == 429 { return .rateLimit }
        if status == 403, let code = QwenWebSearchClient.errorCode(body), code.contains("Quota") { return .quota }
        return nil
    }

    /// Why `model` is skipped now, if it is.
    public func skipped(model: String) -> Reason? {
        let now = clock.now
        return state.withLock { s in
            if let until = s.usedUpUntil[model], now < until { return .quota }
            if let until = s.cooledUntil[model], now < until { return .rateLimit }
            return nil
        }
    }

    /// Why the first model of `job` is skipped now, if it is.
    public func skipped(_ job: QwenRoute.Job) -> Reason? { skipped(model: QwenRoute.route(job).model) }

    /// §36 item 4: the models marked used up now, for the 设置 page's diagnostics.
    public func usedUpModels() -> [String] {
        let now = clock.now
        return state.withLock { s in s.usedUpUntil.filter { now < $0.value }.map(\.key).sorted() }
    }

    /// F-18 §32 item 3: a DashScope reply that says the quota is used up (`QuotaError.dashScope`).
    public static func quotaError(status: Int, body: Data) -> Bool {
        let objects = QwenWebSearchClient.objects(body)
        let code = objects.lazy.compactMap { $0["code"]?.stringValue }.first { !$0.isEmpty }
        let message = objects.lazy.compactMap { $0["message"]?.stringValue }.first
        return QuotaError.dashScope(status: status, code: code, message: message)
    }

    public typealias Attempt = (_ route: QwenRoute, _ timeout: NovaDuration?) async throws -> (status: Int, body: Data)

    /// Runs one request over `route.chain` per the rules above. `attempt` builds and sends the body for the route it
    /// is given (`route.entry` is the model to send); `timeout` is the remaining budget for a later entry (nil: the
    /// caller's own). `request` is the request's content for the §32 repeat key; never logged.
    public func run(_ route: QwenRoute, request: String = "", _ attempt: Attempt) async throws -> (status: Int, body: Data) {
        let started = clock.now
        let open = route.chain.filter { skipped(model: $0.model) != .quota }
        let order = open.filter { skipped(model: $0.model) == nil } + open.filter { skipped(model: $0.model) == .rateLimit }
        guard !order.isEmpty else { throw BudgetRefused(.quota) }
        var last: (status: Int, body: Data)?
        var moved: (from: String, reason: Reason)?
        for (n, entry) in order.enumerated() {
            let r = route.on(entry)
            var timeout: NovaDuration?
            if n > 0, let total = route.budget {
                let left = total - (clock.now - started)
                if left <= .zero { break }
                timeout = left
            }
            if let moved { line("qwen fallback job=\(route.job.rawValue) from=\(moved.from) to=\(entry.model) reason=\(moved.reason.rawValue)") }
            switch ask(r, request) {
            case .allow: break
            case .refuse(.quota):
                // §32 item 3: the budget's breaker says the model is used up today; the next entry is tried.
                moved = (entry.model, .quota)
                continue
            case .refuse(let why): throw BudgetRefused(why)
            }
            let result = try await counted(r, timeout, attempt)
            guard let why = Self.reason(status: result.status, body: result.body) else { return result }
            mark(entry.model, why)
            last = result
            moved = (entry.model, why)
        }
        if let last { return last }
        if moved?.reason == .quota { throw BudgetRefused(.quota) }
        throw URLError(.timedOut)
    }

    private func mark(_ model: String, _ why: Reason) {
        let now = clock.now
        let fresh: Bool = state.withLock { s in
            switch why {
            case .rateLimit:
                s.cooledUntil[model] = now + QwenRoute.cooldown
                return false
            case .quota:
                let was = s.usedUpUntil[model].map { now < $0 } ?? false
                s.usedUpUntil[model] = now + QwenRoute.usedUpFor
                return !was
            }
        }
        if fresh { line("qwen exhausted model=\(model)") }
    }

    private func ask(_ route: QwenRoute, _ request: String) -> BudgetDecision {
        guard let budget else { return .allow }
        let paid = route.job.paid
        return budget.ask(paid, model: route.model, key: CallBudget.key(paid, model: route.model, text: request))
    }

    /// One attempt, reported to the budget (tokens from the reply's `usage`, the quota breaker).
    private func counted(_ route: QwenRoute, _ timeout: NovaDuration?, _ attempt: Attempt) async throws -> (status: Int, body: Data) {
        do {
            let r = try await attempt(route, timeout)
            budget?.done(route.job.paid, model: route.model,
                         ok: r.status == 200 && QwenWebSearchClient.errorCode(r.body) == nil,
                         tokens: CallBudget.reportedTokens(r.body), quotaError: Self.quotaError(status: r.status, body: r.body))
            return r
        } catch {
            budget?.done(route.job.paid, model: route.model, ok: false, tokens: nil)
            throw error
        }
    }

    private func line(_ text: String) {
        state.withLock { $0.log }?(text)
    }
}

extension QwenRoute.Job {
    /// F-18 §32 item 1: the budget's name for the route.
    public var paid: PaidRoute {
        switch self {
        case .live: .qwenLive
        case .picker: .qwenPicker
        case .ground: .qwenGround
        case .planner: .qwenPlanner
        case .eventsLoop, .eventsSearch: .qwenEvents
        }
    }
}

extension URLRequest {
    /// A backup call's remaining budget, as the request's timeout.
    mutating func limit(_ timeout: NovaDuration?) {
        if let timeout { timeoutInterval = Double(timeout.milliseconds) / 1000 }
    }
}
