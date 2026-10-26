import Synchronization
import NovaKit
import NovaPorts
import NovaTools
import NovaVoice

/// The session's F-02 listening lifecycle behind a lock. Every input is stamped with the injected
/// clock and its effects go to `apply`, which the shell turns into real work (stop, disconnect…).
public final class ConversationLifecycle: Sendable {
    private let lifecycle: Mutex<ListeningLifecycle>
    private let clock: any NovaClock
    private let apply: @Sendable ([LifecycleEffect]) async -> Void

    public init(clock: any NovaClock, tuning: ListeningLifecycleTuning = ListeningLifecycleTuning(),
                apply: @escaping @Sendable ([LifecycleEffect]) async -> Void) {
        self.lifecycle = Mutex(ListeningLifecycle(tuning: tuning))
        self.clock = clock
        self.apply = apply
    }

    /// Read back from the state machine itself, never from what was asked (I-14).
    public var state: ListeningState { lifecycle.withLock { $0.state } }

    public func send(_ input: LifecycleInput) async {
        let now = clock.now
        let effects = lifecycle.withLock { $0.handle(input, at: now) }
        if !effects.isEmpty { await apply(effects) }
    }
}

/// `end_conversation` (F-02 §5): ACTIVE/SILENT_WAIT → SLEEP. Reports success only when the
/// lifecycle reads back SLEEP after the input (I-1, I-14).
public struct EndConversationHandler: ToolExecutor {
    public static let tool = "end_conversation"
    private let lifecycle: ConversationLifecycle

    public init(lifecycle: ConversationLifecycle) { self.lifecycle = lifecycle }

    public func execute(_ call: ToolCall) async -> ToolResult {
        await lifecycle.send(.endConversation)
        let state = lifecycle.state
        guard state == .sleep else {
            return ToolDispatcher.failure(.actionNotAllowed, data: ["state": .string(state.rawValue)])
        }
        let next = "对话已结束，只说一句短道别。"
        return .success(["state": .string(state.rawValue), "next": .string(next)])
    }
}

/// Whether replies are voiced. Silent keeps listening and acting; only speech is muted.
public enum SpeechOutputMode: String, Sendable, Hashable, CaseIterable {
    case silent, spoken
}

/// The live speech-output switch the reply path consults before voicing a clause.
public final class SpeechOutputSwitch: Sendable {
    private let current = Mutex(SpeechOutputMode.spoken)
    private let onChange: @Sendable (SpeechOutputMode) async -> Void

    public init(onChange: @escaping @Sendable (SpeechOutputMode) async -> Void = { _ in }) {
        self.onChange = onChange
    }

    public var mode: SpeechOutputMode { current.withLock { $0 } }

    public func set(_ mode: SpeechOutputMode) async {
        let changed = current.withLock { old in
            defer { old = mode }
            return old != mode
        }
        if changed { await onChange(mode) }
    }
}

/// `set_speech_output`: flips the switch and reports the mode read back from it (I-14).
public struct SpeechOutputHandler: ToolExecutor {
    public static let tool = "set_speech_output"
    private let output: SpeechOutputSwitch

    public init(output: SpeechOutputSwitch) { self.output = output }

    public func execute(_ call: ToolCall) async -> ToolResult {
        guard let raw = call.arguments["mode"]?.stringValue, let mode = SpeechOutputMode(rawValue: raw) else {
            return ToolDispatcher.failure(.modeNotAllowed)
        }
        await output.set(mode)
        let actual = output.mode
        let next = actual == .silent ? "已静音，不要再说话。" : "已恢复说话，简短确认一句。"
        return .success(["mode": .string(actual.rawValue), "next": .string(next)])
    }
}
