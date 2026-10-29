import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

private final class FakeCamera: CameraFrameSource {
    let error: CameraError?
    let captures = Mutex(0)
    init(error: CameraError? = nil) { self.error = error }
    func captureStill() async throws -> JPEGImage {
        captures.withLock { $0 += 1 }
        if let error { throw error }
        return JPEGImage(data: [0xFF, 0xD8])
    }
}

/// Answers each question once `release(_:)` is called for it, so tests control the order.
private final class GatedVision: VisionPort {
    private let gates = Mutex<[String: CheckedContinuation<VisionAnswer, Never>]>([:])
    let asked = Mutex<[String]>([])
    func ask(_ question: String, image: JPEGImage) async -> VisionAnswer {
        await withCheckedContinuation { c in
            gates.withLock { $0[question] = c }
            asked.withLock { $0.append(question) }
        }
    }
    func waiting(_ question: String) -> Bool { gates.withLock { $0[question] != nil } }
    func release(_ question: String, _ answer: VisionAnswer) {
        gates.withLock { $0.removeValue(forKey: question) }?.resume(returning: answer)
    }
}

private struct FixedVision: VisionPort {
    let answer: VisionAnswer
    func ask(_ question: String, image: JPEGImage) async -> VisionAnswer { answer }
}

private func until(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<2_000 where !condition() { await Task.yield() }
}

@Suite("T-071a F-20a camera question handler")
struct CameraQuestionHandlerTests {
    @Test("An answer comes back with the time the frame was taken")
    func answers() async {
        let clock = ManualClock(start: NovaInstant(milliseconds: 5_000))
        let handler = CameraQuestionHandler(camera: FakeCamera(), vision: FixedVision(answer: .answer("前面是一辆白色轿车。")),
                                            clock: clock)
        let r = await handler.execute(call("describe_camera_view", ["question": "前面是什么"]))
        #expect(r.ok)
        #expect(r.data["answer"] == .string("前面是一辆白色轿车。"))
        #expect(r.data["seen_at_ms"] == .int(5_000))
    }

    @Test("F-20a §8: no key, permission, camera and auth failures map to their codes; nothing is claimed")
    func failures() async {
        let clock = ManualClock()
        let cases: [(CameraQuestionHandler, ToolErrorCode)] = [
            (CameraQuestionHandler(camera: FakeCamera(), vision: nil, clock: clock), .notConfigured),
            (CameraQuestionHandler(camera: FakeCamera(error: .permissionDenied),
                                   vision: FixedVision(answer: .answer("x")), clock: clock), .cameraPermissionDenied),
            (CameraQuestionHandler(camera: FakeCamera(error: .unavailable),
                                   vision: FixedVision(answer: .answer("x")), clock: clock), .cameraUnavailable),
            (CameraQuestionHandler(camera: FakeCamera(), vision: FixedVision(answer: .notConfigured), clock: clock),
             .notConfigured),
            (CameraQuestionHandler(camera: FakeCamera(), vision: FixedVision(answer: .authFailed), clock: clock),
             .authFailed),
            (CameraQuestionHandler(camera: FakeCamera(), vision: FixedVision(answer: .failed), clock: clock),
             .visionFailed),
        ]
        for (handler, code) in cases {
            let r = await handler.ask("前面是什么")
            #expect(!r.ok)
            #expect(r.code == code)
            #expect(r.data["answer"] == nil)
        }
    }

    @Test("No key: the camera is not even asked for a frame (no image without a usable backend)")
    func noKeyNoCapture() async {
        let camera = FakeCamera()
        let handler = CameraQuestionHandler(camera: camera, vision: nil, clock: ManualClock())
        _ = await handler.ask("前面是什么")
        #expect(camera.captures.withLock { $0 } == 0)
    }

    @Test("8 s deadline: a slow backend gives VISION_FAILED, never a guess")
    func deadline() async {
        let clock = ManualClock()
        let vision = GatedVision()
        let handler = CameraQuestionHandler(camera: FakeCamera(), vision: vision, clock: clock)
        async let r = handler.ask("前面是什么")
        await until { vision.waiting("前面是什么") && clock.pendingSleepers == 1 }
        clock.advance(by: .seconds(8))
        let result = await r
        #expect(result.code == .visionFailed)
        vision.release("前面是什么", .answer("late"))
    }

    @Test("F-20a §10 row 7: a second question cancels the first; only the second answer is returned")
    func supersede() async {
        let clock = ManualClock()
        let vision = GatedVision()
        let handler = CameraQuestionHandler(camera: FakeCamera(), vision: vision, clock: clock)
        async let first = handler.ask("一")
        await until { vision.waiting("一") }
        async let second = handler.ask("二")
        await until { vision.waiting("二") }
        vision.release("二", .answer("第二个答案"))
        vision.release("一", .answer("第一个答案"))
        let (a, b) = await (first, second)
        #expect(a.code == .superseded)
        #expect(b.data["answer"] == .string("第二个答案"))
    }

    @Test("Closing the window drops the answer in flight")
    func cancelOnClose() async {
        let vision = GatedVision()
        let handler = CameraQuestionHandler(camera: FakeCamera(), vision: vision, clock: ManualClock())
        async let r = handler.ask("前面是什么")
        await until { vision.waiting("前面是什么") }
        await handler.cancel()
        vision.release("前面是什么", .answer("x"))
        #expect(await r.code == .superseded)
    }
}
