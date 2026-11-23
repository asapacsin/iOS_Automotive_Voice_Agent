import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import NovaKit
import NovaPorts

/// F-15b §50 item 10 (T-040x, owner 2026-11-19): the backup model of a `QwenRoute` when the primary's budget is used up.
/// Model Studio counts free quota and rate limits per model for the whole account, so another model (not another key)
/// gives more room; gateways do the same (LiteLLM fallbacks and cooldowns).
/// - Switches only for an HTTP 429, a 403 whose error `code` contains `Quota`, or a published quota code (F-18 §32
///   item 3, `QuotaError.dashScope`; a quota 429 skips the primary like a quota 403). Bodies are read whole and a non-200
///   status carries no answer, so a switch never follows a streamed answer (a 200 with an error chunk never switches).
/// - One switch per request, to the route's backup (same body except `model`, and `search_strategy` for `ground`).
/// - The backup gets only what is left of the route's budget (`QwenRoute.budget`); none left: no backup call.
/// - After a 429 the primary is skipped for `QwenRoute.cooldown` (60 s); after a quota 403 until the app restarts.
///   While skipped, the backup is called first (and alone: still one switch per request).
/// - Log: `qwen fallback route=<job> from=<model> to=<model> reason=<429|quota> ok=<yes|no> ms=<ms>` (I-8: numbers,
///   enums and model names only).
public final class QwenFallback: Sendable {
    public enum Reason: String, Sendable, Hashable {
        case rateLimit = "429"
        case quota
    }

    /// One process-wide state, so every client of a route sees the same skip (all keys share the model's limits).
    /// F-18 §32: the app attaches `CallBudget.shared` at start (`setBudget`); tests that use it get none.
    public static let shared = QwenFallback()

    private struct State {
        var skippedUntil: [QwenRoute.Job: NovaInstant] = [:]
        var quotaSkipped: Set<QwenRoute.Job> = []
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

    /// The app's log sink for the fallback line.
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

    /// Why the primary of `job` is skipped now, if it is.
    public func skipped(_ job: QwenRoute.Job) -> Reason? {
        let now = clock.now
        return state.withLock { s in
            if s.quotaSkipped.contains(job) { return .quota }
            if let until = s.skippedUntil[job], now < until { return .rateLimit }
            return nil
        }
    }

    /// F-18 §32 item 3: a DashScope reply that says the quota is used up (`QuotaError.dashScope`).
    public static func quotaError(status: Int, body: Data) -> Bool {
        let objects = QwenWebSearchClient.objects(body)
        let code = objects.lazy.compactMap { $0["code"]?.stringValue }.first { !$0.isEmpty }
        let message = objects.lazy.compactMap { $0["message"]?.stringValue }.first
        return QuotaError.dashScope(status: status, code: code, message: message)
    }

    public typealias Attempt = (_ route: QwenRoute, _ timeout: NovaDuration?) async throws -> (status: Int, body: Data)

    /// Runs one request on `route`, switching once to its backup per the rules above. `attempt` builds and sends the
    /// body for the route it is given; `timeout` is the remaining budget for a backup call (nil: the caller's own).
    /// `request` is the request's content for the §32 repeat key (query, choices, trip input); never logged.
    public func run(_ route: QwenRoute, request: String = "", _ attempt: Attempt) async throws -> (status: Int, body: Data) {
        let started = clock.now
        if let why = skipped(route.job) {
            return try await backup(route, reason: why, started: started, primary: nil, request: request, attempt)
        }
        switch ask(route, request) {
        case .allow: break
        case .refuse(.quota):
            // §32 item 3: the model is used up today; its backup is tried once (its own breaker decides).
            return try await backup(route, reason: .quota, started: started, primary: nil, request: request, attempt)
        case .refuse(let r): throw BudgetRefused(r)
        }
        let first = try await counted(route, nil, attempt)
        guard let why = Self.reason(status: first.status, body: first.body) else { return first }
        let now = clock.now
        // §59 item 2: a route with no backup just fails; no cooldown, so the next request tries the model again.
        guard route.backup != nil else { return first }
        state.withLock { s in
            switch why {
            case .rateLimit: s.skippedUntil[route.job] = now + QwenRoute.cooldown
            case .quota: s.quotaSkipped.insert(route.job)
            }
        }
        return try await backup(route, reason: why, started: started, primary: first, request: request, attempt)
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

    /// The backup call with what is left of the budget. No time left: the primary's reply (or a timeout when the
    /// primary was skipped), so the route's existing failure path runs.
    private func backup(_ route: QwenRoute, reason: Reason, started: NovaInstant, primary: (status: Int, body: Data)?,
                        request: String, _ attempt: Attempt) async throws -> (status: Int, body: Data) {
        guard let backupRoute = route.backup else {
            // §59 item 2: no backup model (picker): the primary's failure stands.
            if let primary { return primary }
            if reason == .quota { throw BudgetRefused(.quota) }
            throw URLError(.timedOut)
        }
        let remaining = route.budget.map { $0 - (clock.now - started) }
        if let remaining, remaining <= .zero {
            line(route, reason, ok: false, started: started)
            if let primary { return primary }
            throw URLError(.timedOut)
        }
        if case .refuse(let r) = ask(backupRoute, request) {
            line(route, reason, ok: false, started: started)
            if let primary { return primary }
            throw BudgetRefused(r)
        }
        do {
            let r = try await counted(backupRoute, remaining, attempt)
            line(route, reason, ok: r.status == 200 && QwenWebSearchClient.errorCode(r.body) == nil, started: started)
            return r
        } catch {
            line(route, reason, ok: false, started: started)
            throw error
        }
    }

    private func line(_ route: QwenRoute, _ reason: Reason, ok: Bool, started: NovaInstant) {
        let ms = (clock.now - started).milliseconds
        let text = "qwen fallback route=\(route.job.rawValue) from=\(route.model) to=\(route.backupModel ?? "none") "
            + "reason=\(reason.rawValue) ok=\(ok ? "yes" : "no") ms=\(ms)"
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
        }
    }
}

extension URLRequest {
    /// A backup call's remaining budget, as the request's timeout.
    mutating func limit(_ timeout: NovaDuration?) {
        if let timeout { timeoutInterval = Double(timeout.milliseconds) / 1000 }
    }
}
