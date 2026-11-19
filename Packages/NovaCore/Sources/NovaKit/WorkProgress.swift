import Synchronization

/// F-15b §50 item 6 (T-040w): the steps shown while she works (a trip being planned, a live-info search). Pure: every
/// call takes the time. The code doing the work feeds it; the screen asks `panel(at:)`. Step lines are fixed texts or
/// counts (no conversation words, I-8).
public struct WorkProgress: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case trip, search }
    public enum State: String, Sendable, Equatable { case pending, running, done, failed }

    public struct Step: Sendable, Equatable {
        public let title: String
        public var state: State
        /// The one short line of a failed step.
        public var line: String?
    }

    /// What the screen shows.
    public struct Panel: Sendable, Equatable {
        public let kind: Kind
        public let steps: [Step]
        /// The last failure line, while it is kept (until the next step, or 3 s after the end).
        public let failure: String?
    }

    /// Quick work shows nothing.
    public static let showAfter = NovaDuration.seconds(1)
    /// A failure line stays this long after the end.
    public static let failureKeep = NovaDuration.seconds(3)
    /// A work never ended (a trip round the model never revised) is hidden after this.
    public static let maxOpen = NovaDuration.seconds(120)

    public static let tripFind = "查找景点和酒店"
    public static let tripCheck = "检查地点位置"
    public static let tripTimes = "计算开车时间"
    public static let tripRevise = "调整行程"
    public static func outOfArea(_ n: Int) -> String { "\(n) 个地方在范围外，正在换" }

    /// The step for a search tool: `web_search` or `query_live_info` with its `kind`.
    public static func searchTitle(tool: String, kind: String?) -> String {
        if tool == "web_search" { return "正在搜索…" }
        return kind == "weather" ? "正在查天气…" : "正在查…"
    }

    public private(set) var kind: Kind?
    public private(set) var steps: [Step] = []
    private var started: NovaInstant?
    private var ended: NovaInstant?
    /// The step index whose failure line is kept, nil when none.
    private var failureAt: Int?

    public init() {}

    /// Starts a new work, replacing any other.
    public mutating func start(_ kind: Kind, at now: NovaInstant) {
        self = WorkProgress()
        self.kind = kind
        started = now
    }

    /// An open work older than `maxOpen`.
    public func stale(at now: NovaInstant) -> Bool {
        guard let started else { return false }
        return now - started >= Self.maxOpen
    }

    /// True while a work is open (started, not ended or cleared).
    public var open: Bool { kind != nil && ended == nil }

    /// The next step starts: the running one is done, and a kept failure line goes. The same title as the running
    /// step changes nothing.
    public mutating func step(_ title: String, at now: NovaInstant) {
        guard open else { return }
        if let last = steps.last, last.state == .running, last.title == title { return }
        if let i = steps.indices.last, steps[i].state == .running { steps[i].state = .done }
        failureAt = nil
        steps.append(Step(title: title, state: .running, line: nil))
    }

    /// The running step failed with one short line.
    public mutating func fail(_ line: String, at now: NovaInstant) {
        guard open, let i = steps.indices.last else { return }
        steps[i].state = .failed
        steps[i].line = line
        failureAt = i
    }

    /// The work ended. Returns the `work show=` log line when the panel was shown.
    public mutating func end(at now: NovaInstant) -> String? {
        guard open, let started else { return nil }
        if let i = steps.indices.last, steps[i].state == .running { steps[i].state = .done }
        ended = now
        let line = logLine(at: now, since: started)
        if failureAt == nil { self = WorkProgress() }
        return line
    }

    /// The result arrived (the trip cards, or the answer): nothing is shown any more. Returns the log line when an
    /// open work was shown.
    public mutating func clear(at now: NovaInstant) -> String? {
        let line: String? = if open, let started { logLine(at: now, since: started) } else { nil }
        self = WorkProgress()
        return line
    }

    public func panel(at now: NovaInstant) -> Panel? {
        guard let kind, let started, !steps.isEmpty else { return nil }
        guard now - started >= Self.showAfter, now - started < Self.maxOpen else { return nil }
        let failure = failureAt.map { steps[$0].line } ?? nil
        if let ended {
            guard ended - started >= Self.showAfter, failure != nil, now - ended < Self.failureKeep else { return nil }
        }
        return Panel(kind: kind, steps: steps, failure: failure)
    }

    private func logLine(at now: NovaInstant, since started: NovaInstant) -> String? {
        guard let kind, now - started >= Self.showAfter else { return nil }
        let failed = steps.filter { $0.state == .failed }.count
        return "work show=\(kind.rawValue) steps=\(steps.count) failed=\(failed) ms=\((now - started).milliseconds)"
    }
}

/// The app's one `WorkProgress`, fed from any task with the injected clock; `onLog` gets the `work show=` line.
public final class WorkProgressBoard: Sendable {
    private let state = Mutex(WorkProgress())
    private let clock: any NovaClock
    private let onLog: @Sendable (String) -> Void

    public init(clock: any NovaClock, onLog: @escaping @Sendable (String) -> Void = { _ in }) {
        self.clock = clock
        self.onLog = onLog
    }

    public func start(_ kind: WorkProgress.Kind, step title: String? = nil) {
        let now = clock.now
        state.withLock {
            $0.start(kind, at: now)
            if let title { $0.step(title, at: now) }
        }
    }

    /// Starts a trip work only when none is open (a `revise_trip_list` round continues the make's panel).
    public func continueTrip() {
        let now = clock.now
        // An open trip work older than `maxOpen` (a round never revised) is stale: start a fresh one.
        state.withLock {
            if !($0.open && $0.kind == .trip && !$0.stale(at: now)) { $0.start(.trip, at: now) }
        }
    }

    public func step(_ title: String) {
        let now = clock.now
        state.withLock { $0.step(title, at: now) }
    }

    public func fail(_ line: String) {
        let now = clock.now
        state.withLock { $0.fail(line, at: now) }
    }

    public func end() {
        let now = clock.now
        if let line = state.withLock({ $0.end(at: now) }) { onLog(line) }
    }

    /// Clears only a work of `kind` (the trip cards never clear a search panel), or any when nil.
    public func clear(_ kind: WorkProgress.Kind? = nil) {
        let now = clock.now
        let line = state.withLock { p -> String? in
            guard kind == nil || p.kind == kind else { return nil }
            return p.clear(at: now)
        }
        if let line { onLog(line) }
    }

    public var panel: WorkProgress.Panel? {
        let now = clock.now
        return state.withLock { $0.panel(at: now) }
    }
}
