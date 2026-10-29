import NovaKit
import NovaPorts
import Synchronization

/// `describe_camera_view` (F-20, F-20a): one still at the moment of the question, one vision request
/// in flight, 8 s deadline. A newer question or `cancel()` (window closed) drops the older answer, so
/// it is never spoken. The image and question are never logged (I-8).
/// F-20b: the question picks 前方 or 后方 (argument, else its words, else the lens showing) and the window
/// switches before the still is taken. Switches and stills take turns: a question waits for a switch, a
/// switch waits until the still is taken, and a switch never cancels a question.
public actor CameraQuestionHandler: ToolExecutor {
    public static let tools: Set<String> = ["describe_camera_view"]
    /// The tap path (问一下) asks this fixed question.
    public static let tapQuestion = "画面里有什么？请简短描述。"

    private let camera: any CameraFrameSource
    private let vision: (any VisionPort)?
    private let clock: any NovaClock
    private let deadline: NovaDuration
    private let lensChanged: @Sendable (CameraLens) -> Void
    private var generation: UInt64 = 0
    /// The lens the window shows; the first open of a session uses 前方 (F-20b §2).
    public private(set) var lens: CameraLens = .frontView
    private var switching = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(camera: any CameraFrameSource, vision: (any VisionPort)?, clock: any NovaClock,
                deadline: NovaDuration = .seconds(8), lensChanged: @escaping @Sendable (CameraLens) -> Void = { _ in }) {
        self.camera = camera
        self.vision = vision
        self.clock = clock
        self.deadline = deadline
        self.lensChanged = lensChanged
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        await ask(call.arguments["question"]?.stringValue ?? "",
                  camera: call.arguments["camera"]?.stringValue.flatMap(CameraLens.init(rawValue:)))
    }

    /// Asks one question; also the tap path (no `camera`: the lens showing). Any earlier question still in
    /// flight is superseded.
    public func ask(_ question: String, camera named: CameraLens? = nil) async -> ToolResult {
        generation += 1
        let mine = generation
        guard let vision else {
            return .failure(.notConfigured, advice: "看图功能还没有配置。请如实说明，不要描述画面。")
        }
        await acquire()
        // Cancelled or superseded while waiting for a switch: never switch the lens for a dropped question.
        guard mine == generation else {
            release()
            return Self.dropped
        }
        let target = named ?? CameraLensChooser.choose(question, current: lens)
        let seenAt: NovaInstant
        let image: JPEGImage
        do {
            defer { release() }
            if target != lens {
                try await camera.select(target)
                show(target)
            }
            seenAt = clock.now
            image = try await camera.captureStill()
        } catch CameraError.permissionDenied {
            return mine == generation
                ? .failure(.cameraPermissionDenied, advice: "摄像头没有权限，请在设置里允许。请如实说明，不要描述画面。")
                : Self.dropped
        } catch {
            guard mine == generation else { return Self.dropped }
            return target == .rearView
                ? .failure(.cameraUnavailable, advice: "后面的摄像头现在用不了。请如实说明，不要描述画面。")
                : .failure(.cameraUnavailable, advice: "摄像头现在用不了。请如实说明，不要描述画面。")
        }
        guard mine == generation else { return Self.dropped }
        let answer = await withDeadline { await vision.ask(question, image: image) }
        guard mine == generation else { return Self.dropped }
        switch answer {
        case .answer(let text):
            return .success([
                "answer": .string(text),
                "seen_at_ms": .int(seenAt.milliseconds),
                "camera": .string(target.rawValue),
                "next": .string("只按 answer 回答，用一两句话，不要补充画面里没有的东西。"),
            ])
        case .notConfigured:
            return .failure(.notConfigured, advice: "看图功能还没有配置。请如实说明，不要描述画面。")
        case .authFailed:
            return .failure(.authFailed, advice: "看图服务的密钥无效。请如实说明，不要描述画面。")
        case .failed, nil:
            return .failure(.visionFailed, advice: "刚才没看清楚，再问我一次吧。请如实说明，不要猜。")
        }
    }

    /// The switch button: the other lens within 1 s. Ignored while a switch runs; waits for a still being
    /// taken. On failure the old lens stays (CAMERA_SWITCH_FAILED, logged by the caller). Returns the lens
    /// now showing, or nil when the tap was ignored or failed.
    @discardableResult
    public func switchLens() async -> CameraLens? {
        guard !switching else { return nil }
        switching = true
        defer { switching = false }
        await acquire()
        defer { release() }
        let target: CameraLens = lens == .frontView ? .rearView : .frontView
        do {
            try await camera.select(target)
        } catch {
            return nil
        }
        show(target)
        return target
    }

    private func show(_ target: CameraLens) {
        lens = target
        lensChanged(target)
    }

    /// One camera operation (switch or still) at a time, first come first served.
    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Window closed, app backgrounded or session stopped: the question in flight is dropped.
    public func cancel() {
        generation += 1
    }

    private static let dropped = ToolResult.failure(.superseded, advice: "这个问题已被新的问题取代，不要回答它。")

    /// The vision answer, or nil when the deadline passes first. Returns at the deadline even if the
    /// backend ignores cancellation (a task group would wait for it).
    private func withDeadline(_ work: @escaping @Sendable () async -> VisionAnswer) async -> VisionAnswer? {
        let clock = self.clock
        let end = clock.now + deadline
        let race = FirstWins<VisionAnswer?>()
        return await withCheckedContinuation { continuation in
            race.set(continuation)
            let request = Task { race.finish(await work()) }
            let timer = Task {
                try? await clock.sleep(until: end)
                if race.finish(nil) { request.cancel() }
            }
            race.onFinish { timer.cancel() }
        }
    }
}

/// Resumes one continuation with whichever result arrives first.
private final class FirstWins<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Never>?
        var done = false
        var cleanup: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())

    func set(_ continuation: CheckedContinuation<T, Never>) {
        state.withLock { $0.continuation = continuation }
    }

    /// Runs `cleanup` when the race ends (now, if it already has).
    func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
        let ended = state.withLock { s in
            if !s.done { s.cleanup = cleanup }
            return s.done
        }
        if ended { cleanup() }
    }

    /// True when this call won the race.
    @discardableResult
    func finish(_ value: T) -> Bool {
        let won: (CheckedContinuation<T, Never>?, (@Sendable () -> Void)?)? = state.withLock { s in
            guard !s.done else { return nil }
            s.done = true
            defer { s.continuation = nil; s.cleanup = nil }
            return (s.continuation, s.cleanup)
        }
        guard let won else { return false }
        won.0?.resume(returning: value)
        won.1?()
        return true
    }
}
