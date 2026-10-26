import NovaKit
import NovaPorts

/// `describe_camera_view` (F-20, F-20a): one still at the moment of the question, one vision request
/// in flight, 8 s deadline. A newer question or `cancel()` (window closed) drops the older answer, so
/// it is never spoken. The image and question are never logged (I-8).
public actor CameraQuestionHandler: ToolExecutor {
    public static let tools: Set<String> = ["describe_camera_view"]
    /// The tap path (问一下) asks this fixed question.
    public static let tapQuestion = "画面里有什么？请简短描述。"

    private let camera: any CameraFrameSource
    private let vision: (any VisionPort)?
    private let clock: any NovaClock
    private let deadline: NovaDuration
    private var generation: UInt64 = 0

    public init(camera: any CameraFrameSource, vision: (any VisionPort)?, clock: any NovaClock,
                deadline: NovaDuration = .seconds(8)) {
        self.camera = camera
        self.vision = vision
        self.clock = clock
        self.deadline = deadline
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        await ask(call.arguments["question"]?.stringValue ?? "")
    }

    /// Asks one question; also the tap path. Any earlier question still in flight is superseded.
    public func ask(_ question: String) async -> ToolResult {
        generation += 1
        let mine = generation
        guard let vision else {
            return .failure(.notConfigured, advice: "看图功能还没有配置。请如实说明，不要描述画面。")
        }
        let seenAt = clock.now
        let image: JPEGImage
        do {
            image = try await camera.captureStill()
        } catch CameraError.permissionDenied {
            return mine == generation
                ? .failure(.cameraPermissionDenied, advice: "摄像头没有权限，请在设置里允许。请如实说明，不要描述画面。")
                : Self.dropped
        } catch {
            return mine == generation
                ? .failure(.cameraUnavailable, advice: "摄像头现在用不了。请如实说明，不要描述画面。")
                : Self.dropped
        }
        guard mine == generation else { return Self.dropped }
        let answer = await withDeadline { await vision.ask(question, image: image) }
        guard mine == generation else { return Self.dropped }
        switch answer {
        case .answer(let text):
            return .success([
                "answer": .string(text),
                "seen_at_ms": .int(seenAt.milliseconds),
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

    /// Window closed, app backgrounded or session stopped: the question in flight is dropped.
    public func cancel() {
        generation += 1
    }

    private static let dropped = ToolResult.failure(.superseded, advice: "这个问题已被新的问题取代，不要回答它。")

    /// The vision answer, or nil when the deadline passes first.
    private func withDeadline(_ work: @escaping @Sendable () async -> VisionAnswer) async -> VisionAnswer? {
        let clock = self.clock
        let end = clock.now + deadline
        return await withTaskGroup(of: VisionAnswer?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await clock.sleep(until: end)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
