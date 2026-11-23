import Synchronization

/// F-04 §15 (T-004k): the tool calls running now, in start order. The caption next to the status caption shows while
/// the list is not empty: on at the call, off at its result (ok, refused, timed out or cancelled). No timers. The
/// caption text is fixed per tool (no conversation words, I-8).
public struct BackgroundWork: Sendable, Equatable {
    public struct Call: Sendable, Equatable {
        public let id: CallID
        public let tool: String
        /// `query_live_info`'s `kind` (weather or other), nil for other tools.
        public let kind: String?
        public init(id: CallID, tool: String, kind: String?) {
            self.id = id
            self.tool = tool
            self.kind = kind
        }
    }

    public private(set) var calls: [Call] = []

    public init() {}

    /// Item 2: on exactly while a call runs.
    public var on: Bool { !calls.isEmpty }

    /// Item 1: one call's text.
    public static func text(tool: String, kind: String?) -> String {
        switch tool {
        case "web_search": "正在搜索…"
        case "query_live_info": kind == "weather" ? "正在查天气…" : "正在查…"
        case "set_trip_plan": "正在改行程…"
        default: "正在处理…"
        }
    }

    /// Item 1: the newest call's text; with two or more running, 「等 N 项」 (N = how many run). nil when none runs.
    public var caption: String? {
        guard let newest = calls.last else { return nil }
        let text = Self.text(tool: newest.tool, kind: newest.kind)
        return calls.count >= 2 ? "\(text) 等 \(calls.count) 项" : text
    }

    /// A call started. Returns true when the list changed.
    @discardableResult
    public mutating func start(_ call: Call) -> Bool {
        guard !calls.contains(where: { $0.id == call.id }) else { return false }
        calls.append(call)
        return true
    }

    /// A call's result came back (any result) or it was cancelled. Returns true when it was in the list.
    @discardableResult
    public mutating func end(_ id: CallID) -> Bool {
        guard let i = calls.firstIndex(where: { $0.id == id }) else { return false }
        calls.remove(at: i)
        return true
    }

    /// Item 2: a session end or reconnect empties the list. Returns true when it was not empty.
    @discardableResult
    public mutating func clear() -> Bool {
        guard on else { return false }
        calls = []
        return true
    }
}

/// F-04 §15 item 5 (T-004k): the one running-call list, fed by the tool runner from any task; the caption, the screen
/// state and the record read it. `onChange` gets each new list.
public final class BackgroundWorkBoard: Sendable {
    private let state = Mutex(BackgroundWork())
    private let listener = Mutex<(@Sendable (BackgroundWork) -> Void)?>(nil)

    public init() {}

    public func onChange(_ listener: (@Sendable (BackgroundWork) -> Void)?) { self.listener.withLock { $0 = listener } }

    public var current: BackgroundWork { state.withLock { $0 } }

    public func start(_ call: BackgroundWork.Call) { change { $0.start(call) } }
    public func end(_ id: CallID) { change { $0.end(id) } }
    public func clear() { change { $0.clear() } }

    private func change(_ edit: (inout BackgroundWork) -> Bool) {
        let changed: BackgroundWork? = state.withLock { work in edit(&work) ? work : nil }
        guard let changed else { return }
        listener.withLock { $0 }?(changed)
    }
}
