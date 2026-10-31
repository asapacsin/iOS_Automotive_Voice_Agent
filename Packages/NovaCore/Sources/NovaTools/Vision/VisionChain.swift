import NovaKit
import NovaPorts

/// Which vision service answered or was tried (F-20a §14 item 6 logs).
public enum VisionBackendName: String, Sendable, Hashable {
    case glm, gemini, qianfan
}

/// One link of the chain: a backend that is used only while its key is saved.
public struct VisionBackend: Sendable {
    public let name: VisionBackendName
    public let hasKey: @Sendable () -> Bool
    public let port: any VisionPort

    public init(_ name: VisionBackendName, hasKey: @escaping @Sendable () -> Bool, port: any VisionPort) {
        self.name = name
        self.hasKey = hasKey
        self.port = port
    }
}

/// F-20a §14 item 3: the same photo goes to each saved backend in order (GLM → Gemini → Qianfan) until one
/// answers. The first gets at most 4.5 s, each next one the time left of 8 s, and none is started with less
/// than 1.5 s left. One request per backend per question. Logs carry codes and times only (I-7, I-8).
public struct VisionChain: VisionPort {
    public static let total = NovaDuration.seconds(8)
    public static let firstBudget = NovaDuration.milliseconds(4_500)
    public static let minimumLeft = NovaDuration.milliseconds(1_500)

    private let backends: [VisionBackend]
    private let clock: any NovaClock
    private let log: @Sendable (String) -> Void

    public init(_ backends: [VisionBackend], clock: any NovaClock, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.backends = backends
        self.clock = clock
        self.log = log
    }

    public func ask(_ question: String, image: JPEGImage) async -> VisionAnswer {
        await reply(question, image: image).answer
    }

    public func reply(_ question: String, image: JPEGImage) async -> VisionReply {
        let start = clock.now
        let end = start + Self.total
        var tried = false
        var sawBusy = false
        var sawAuth = false
        for backend in backends where backend.hasKey() {
            if Task.isCancelled { break }
            let left = end - clock.now
            if tried && left < Self.minimumLeft { break }
            let budget = tried ? left : min(left, Self.firstBudget)
            guard budget > .zero else { break }
            tried = true
            let attemptStart = clock.now
            let port = backend.port
            let result = await within(budget) { await port.reply(question, image: image) }
                ?? VisionReply(.busy, status: "timeout")
            let ms = (clock.now - attemptStart).milliseconds
            log("visionAttempt backend=\(backend.name.rawValue) result=\(Self.label(result.answer)) status=\(result.status) ms=\(ms)")
            switch result.answer {
            case .answer:
                log("visionResult backend=\(backend.name.rawValue) code=none totalMs=\((clock.now - start).milliseconds)")
                return result
            case .busy: sawBusy = true
            case .authFailed: sawAuth = true
            case .failed, .notConfigured: break
            }
        }
        let answer: VisionAnswer = !tried ? .notConfigured : sawBusy ? .busy : sawAuth ? .authFailed : .failed
        let code: ToolErrorCode = switch answer {
        case .notConfigured: .notConfigured
        case .busy: .visionBusy
        case .authFailed: .authFailed
        default: .visionFailed
        }
        log("visionResult backend=none code=\(code.rawValue) totalMs=\((clock.now - start).milliseconds)")
        return VisionReply(answer, status: "-")
    }

    static func label(_ answer: VisionAnswer) -> String {
        switch answer {
        case .answer: "answer"
        case .busy: "busy"
        case .authFailed: "auth"
        case .failed: "failed"
        case .notConfigured: "notConfigured"
        }
    }

    /// The reply, or nil when `budget` passes first; returns at the budget even if the backend ignores
    /// cancellation.
    private func within(_ budget: NovaDuration,
                        _ work: @escaping @Sendable () async -> VisionReply) async -> VisionReply? {
        let clock = self.clock
        let deadline = clock.now + budget
        let race = FirstWins<VisionReply?>()
        // A cancelled caller is not waited for here: the handler already dropped it, and the loop stops after.
        return await withCheckedContinuation { continuation in
            race.set(continuation)
            let request = Task { race.finish(await work()) }
            let timer = Task {
                try? await clock.sleep(until: deadline)
                if race.finish(nil) { request.cancel() }
            }
            race.onFinish { timer.cancel() }
        }
    }
}
