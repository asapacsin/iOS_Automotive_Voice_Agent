import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import NovaKit

/// F-15b §50 item 10 (T-040x, owner 2026-11-19): the backup model of a `QwenRoute` when the primary's budget is used up.
/// Model Studio counts free quota and rate limits per model for the whole account, so another model (not another key)
/// gives more room; gateways do the same (LiteLLM fallbacks and cooldowns).
/// - Switches only for an HTTP 429, or a 403 whose error `code` contains `Quota`. Bodies are read whole and a non-200
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
    public static let shared = QwenFallback()

    private struct State {
        var skippedUntil: [QwenRoute.Job: NovaInstant] = [:]
        var quotaSkipped: Set<QwenRoute.Job> = []
        var log: (@Sendable (String) -> Void)?
    }

    private let clock: any NovaClock
    private let state: Mutex<State>

    public init(clock: any NovaClock = SystemClock(), log: (@Sendable (String) -> Void)? = nil) {
        self.clock = clock
        state = Mutex(State(log: log))
    }

    /// The app's log sink for the fallback line.
    public func setLog(_ log: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.log = log }
    }

    /// Only a 429, or a 403 whose error code contains `Quota`. Anything else (401, `InvalidApiKey`, 5xx): nil.
    public static func reason(status: Int, body: Data) -> Reason? {
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

    public typealias Attempt = (_ route: QwenRoute, _ timeout: NovaDuration?) async throws -> (status: Int, body: Data)

    /// Runs one request on `route`, switching once to its backup per the rules above. `attempt` builds and sends the
    /// body for the route it is given; `timeout` is the remaining budget for a backup call (nil: the caller's own).
    public func run(_ route: QwenRoute, _ attempt: Attempt) async throws -> (status: Int, body: Data) {
        let started = clock.now
        if let why = skipped(route.job) {
            return try await backup(route, reason: why, started: started, primary: nil, attempt)
        }
        let first = try await attempt(route, nil)
        guard let why = Self.reason(status: first.status, body: first.body) else { return first }
        let now = clock.now
        state.withLock { s in
            switch why {
            case .rateLimit: s.skippedUntil[route.job] = now + QwenRoute.cooldown
            case .quota: s.quotaSkipped.insert(route.job)
            }
        }
        return try await backup(route, reason: why, started: started, primary: first, attempt)
    }

    /// The backup call with what is left of the budget. No time left: the primary's reply (or a timeout when the
    /// primary was skipped), so the route's existing failure path runs.
    private func backup(_ route: QwenRoute, reason: Reason, started: NovaInstant, primary: (status: Int, body: Data)?,
                        _ attempt: Attempt) async throws -> (status: Int, body: Data) {
        let remaining = route.budget.map { $0 - (clock.now - started) }
        if let remaining, remaining <= .zero {
            line(route, reason, ok: false, started: started)
            if let primary { return primary }
            throw URLError(.timedOut)
        }
        do {
            let r = try await attempt(route.backup, remaining)
            line(route, reason, ok: r.status == 200 && QwenWebSearchClient.errorCode(r.body) == nil, started: started)
            return r
        } catch {
            line(route, reason, ok: false, started: started)
            throw error
        }
    }

    private func line(_ route: QwenRoute, _ reason: Reason, ok: Bool, started: NovaInstant) {
        let ms = (clock.now - started).milliseconds
        let text = "qwen fallback route=\(route.job.rawValue) from=\(route.model) to=\(route.backupModel) "
            + "reason=\(reason.rawValue) ok=\(ok ? "yes" : "no") ms=\(ms)"
        state.withLock { $0.log }?(text)
    }
}

extension URLRequest {
    /// A backup call's remaining budget, as the request's timeout.
    mutating func limit(_ timeout: NovaDuration?) {
        if let timeout { timeoutInterval = Double(timeout.milliseconds) / 1000 }
    }
}
