import Synchronization

/// F-15b §50 item 6 (T-040w): the steps shown while she works (a trip being planned, a live-info search). Pure: every
/// call takes the time. The code doing the work feeds it; the screen asks `panel(at:)`. Step lines are fixed texts or
/// counts (no conversation words, I-8).
public struct WorkProgress: Sendable, Equatable {
    /// F-15b §62 item 12 (T-040zo): `handoff` is `plan_trip`'s spinner row (it replaces §60's trip panel for it and
    /// does not close with the trip screen).
    public enum Kind: String, Sendable, Equatable { case trip, search, handoff }
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
        /// F-15b §62 item 12 (T-040zo): the spinner row's one line, the step the backend is on now (the result line
        /// once it ended), and whether the circle turns (false once the result is in).
        public var line: String { steps.last?.title ?? "" }
        public var spinning: Bool { steps.last?.state == .running }
    }

    /// Quick work shows nothing.
    public static let showAfter = NovaDuration.seconds(1)
    /// A failure line stays this long after the end.
    public static let failureKeep = NovaDuration.seconds(3)
    /// A search work never ended is hidden after this. F-15b §60 item 5 (T-040zm): not for trip work (a running
    /// `set_trip_plan` call always returns, §52 item 11 limits it).
    public static let maxOpen = NovaDuration.seconds(120)

    public static let tripFind = "查找景点和酒店"
    public static let tripCheck = "检查地点位置"
    public static let tripTimes = "计算开车时间"
    public static func outOfArea(_ n: Int) -> String { "\(n) 个地方在范围外，正在换" }
    /// F-15b §58 item 5 (T-040zk): the steps of a trip edit (a `set_trip_plan` that keeps the plan's ids).
    public static let tripEdit = "正在改行程"
    public static func tripFinding(_ name: String) -> String { "正在找\(name)" }
    public static func tripAdded(_ names: [String]) -> String { "已加入" + names.joined(separator: "、") }
    /// F-15b §61 item 5 (T-040zn): a saved edit (was 「已改好」), a refused write (was 「没改成：…」), and the panel while
    /// `check_trip_plan` runs. The words say what happened (stored, not stored), never that the trip is done.
    public static let tripUpdated = "行程已更新"
    public static func tripNotSaved(_ line: String) -> String { "没保存：\(line)" }
    public static let tripChecking = "正在核对行程"
    /// F-15b §62 items 9, 12 (T-040zo): `plan_trip`'s steps on the spinner row, exactly as §62 gives them.
    public static let handedOver = "已交给规划助手"
    public static let tripPlanning = "正在规划行程"
    public static func tripCounting(_ round: Int) -> String { "正在核对路线（第\(round)轮）" }
    public static func tripRevising(_ round: Int) -> String { "正在修改行程（第\(round)轮）" }
    /// §62 item 12: `web_search`, `query_live_info` and `show_place` on the same row while they run.
    public static func lookingUp(_ what: String) -> String { "正在查：\(what)" }
    /// §58 item 5: an edit's ok line stays 3 s; its refusal line until the next step or 5 s.
    public static let editDoneKeep = NovaDuration.seconds(3)
    public static let editFailedKeep = NovaDuration.seconds(5)

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
    /// §58 item 5: an edit's last line (`finish`) is shown until then, quick or not.
    private var noticeUntil: NovaInstant?

    public init() {}

    /// F-15b §62 item 12 (T-040zo): the spinner row shows from the first moment (no `showAfter`).
    private var immediate = false

    /// Starts a new work, replacing any other. `immediate`: shown at once (the §62 spinner row).
    public mutating func start(_ kind: Kind, at now: NovaInstant, immediate: Bool = false) {
        self = WorkProgress()
        self.kind = kind
        self.immediate = immediate
        started = now
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

    /// F-15b §58 item 5 (T-040zk): a trip edit ended with its line (「已加入…」/「已改好」 done, 「没改成：…」 failed), shown
    /// at once for `editDoneKeep` / `editFailedKeep`, or until the next work starts.
    public mutating func finish(_ line: String, failed: Bool, at now: NovaInstant) {
        guard open else { return }
        if let i = steps.indices.last, steps[i].state == .running { steps[i].state = .done }
        steps.append(Step(title: line, state: failed ? .failed : .done, line: nil))
        ended = now
        failureAt = nil
        noticeUntil = now + (failed ? Self.editFailedKeep : Self.editDoneKeep)
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
        if let noticeUntil { return now < noticeUntil ? Panel(kind: kind, steps: steps, failure: nil) : nil }
        let shown = immediate || now - started >= Self.showAfter
        guard shown, kind != .search || now - started < Self.maxOpen else { return nil }
        let failure = failureAt.map { steps[$0].line } ?? nil
        if let ended {
            guard immediate || ended - started >= Self.showAfter, failure != nil, now - ended < Self.failureKeep else { return nil }
        }
        return Panel(kind: kind, steps: steps, failure: failure)
    }

    private func logLine(at now: NovaInstant, since started: NovaInstant) -> String? {
        guard let kind, immediate || now - started >= Self.showAfter else { return nil }
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

    public func start(_ kind: WorkProgress.Kind, step title: String? = nil, immediate: Bool = false) {
        let now = clock.now
        state.withLock {
            // F-15b §62 item 12 (T-040zo, review): a search while `plan_trip` runs never replaces its row; the row
            // stays on until the planner's result.
            if kind == .search, $0.kind == .handoff, $0.open { return }
            $0.start(kind, at: now, immediate: immediate)
            if let title { $0.step(title, at: now) }
        }
    }

    /// F-15b §60 item 3 (T-040zm): the trip screen reported off: a trip work panel goes off at once. §62 item 12
    /// (T-040zo): `plan_trip`'s spinner row (`handoff`) stays: the work still runs.
    public func tripScreen(on: Bool) {
        if !on { clear(.trip) }
    }

    public func step(_ title: String) {
        let now = clock.now
        state.withLock { $0.step(title, at: now) }
    }

    public func fail(_ line: String) {
        let now = clock.now
        state.withLock { $0.fail(line, at: now) }
    }

    /// §58 item 5: a trip edit's last line (`WorkProgress.finish`).
    public func finish(_ line: String, failed: Bool) {
        let now = clock.now
        state.withLock { $0.finish(line, failed: failed, at: now) }
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
