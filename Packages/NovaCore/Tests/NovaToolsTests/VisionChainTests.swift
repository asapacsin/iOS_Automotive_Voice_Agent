import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// Replies with a fixed answer, or hangs until cancelled when `answer` is nil.
private final class FakeBackend: VisionPort {
    let answer: VisionAnswer?
    let status: String
    let calls = Mutex(0)
    init(_ answer: VisionAnswer?, status: String = "200") {
        self.answer = answer
        self.status = status
    }
    func ask(_ question: String, image: JPEGImage) async -> VisionAnswer { await reply(question, image: image).answer }
    func reply(_ question: String, image: JPEGImage) async -> VisionReply {
        calls.withLock { $0 += 1 }
        guard let answer else {
            while !Task.isCancelled { await Task.yield() }
            return VisionReply(.failed, status: "cancelled")
        }
        return VisionReply(answer, status: status)
    }
    var count: Int { calls.withLock { $0 } }
}

private final class Lines: Sendable {
    let all = Mutex<[String]>([])
    func add(_ line: String) { all.withLock { $0.append(line) } }
    var list: [String] { all.withLock { $0 } }
}

private struct Camera: CameraFrameSource {
    func captureStill() async throws -> JPEGImage { JPEGImage(data: [0xFF, 0xD8, 0x42]) }
}

private func until(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<5_000 where !condition() { await Task.yield() }
}

private let image = JPEGImage(data: [0xFF, 0xD8, 0x42])

@Suite("T-071h F-20a §14 vision chain")
struct VisionChainTests {
    fileprivate func chain(glm: FakeBackend?, gemini: FakeBackend?, qianfan: FakeBackend?, clock: any NovaClock = ManualClock(),
               lines: Lines = Lines()) -> VisionChain {
        VisionChain([
            VisionBackend(.glm, hasKey: { glm != nil }, port: glm ?? FakeBackend(.failed)),
            VisionBackend(.gemini, hasKey: { gemini != nil }, port: gemini ?? FakeBackend(.failed)),
            VisionBackend(.qianfan, hasKey: { qianfan != nil }, port: qianfan ?? FakeBackend(.failed)),
        ], clock: clock, log: lines.add)
    }

    @Test("Row 1: GLM answers; Gemini and Qianfan are not called")
    func glmFirst() async {
        let g = FakeBackend(.answer("红灯")), m = FakeBackend(.answer("x")), q = FakeBackend(.answer("y"))
        #expect(await chain(glm: g, gemini: m, qianfan: q).ask("q", image: image) == .answer("红灯"))
        #expect(m.count == 0 && q.count == 0)
    }

    @Test("Row 2: GLM busy (503), Gemini answers; two attempt lines and visionResult backend=gemini")
    func fallback() async {
        let lines = Lines()
        let c = chain(glm: FakeBackend(.busy, status: "503"), gemini: FakeBackend(.answer("绿灯")), qianfan: nil,
                      lines: lines)
        #expect(await c.ask("q", image: image) == .answer("绿灯"))
        let attempts = lines.list.filter { $0.hasPrefix("visionAttempt") }
        #expect(attempts == ["visionAttempt backend=glm result=busy status=503 ms=0",
                             "visionAttempt backend=gemini result=answer status=200 ms=0"])
        #expect(lines.list.last?.hasPrefix("visionResult backend=gemini code=none totalMs=") == true)
    }

    @Test("Row 3: GLM 429, Gemini 503, no Qianfan key: VISION_BUSY with the busy advice, never 没看清楚")
    func allBusy() async {
        let c = chain(glm: FakeBackend(.busy, status: "429"), gemini: FakeBackend(.busy, status: "503"), qianfan: nil)
        #expect(await c.ask("q", image: image) == .busy)
        let handler = CameraQuestionHandler(camera: Camera(), vision: c, clock: ManualClock())
        let r = await handler.ask("前面是什么")
        #expect(r.code == .visionBusy)
        #expect(r.advice?.hasPrefix("识图服务现在忙或者连不上") == true)
        #expect(r.advice?.contains("没看清") == false)
    }

    @Test("Row 4: GLM hangs: cut at 4.5 s, Gemini gets the 3.5 s left, whole question ends by 8 s")
    func budget() async {
        let clock = ManualClock()
        let lines = Lines()
        let glm = FakeBackend(nil), gemini = FakeBackend(nil)
        let c = chain(glm: glm, gemini: gemini, qianfan: FakeBackend(.answer("never")), clock: clock, lines: lines)
        async let answer = c.ask("q", image: image)
        await until { glm.count == 1 && clock.pendingSleepers == 1 }
        clock.advance(by: .milliseconds(4_499))
        await until { false }
        #expect(gemini.count == 0)
        clock.advance(by: .milliseconds(1))
        await until { gemini.count == 1 && clock.pendingSleepers == 1 }
        #expect(gemini.count == 1)
        clock.advance(by: .milliseconds(3_500))
        #expect(await answer == .busy)
        #expect(lines.list.contains("visionAttempt backend=glm result=busy status=timeout ms=4500"))
        #expect(lines.list.contains("visionAttempt backend=gemini result=busy status=timeout ms=3500"))
        #expect(lines.list.contains("visionResult backend=none code=VISION_BUSY totalMs=8000"))
        // Qianfan had 0 s left (< 1.5 s), so it was never started.
        #expect(!lines.list.contains { $0.contains("backend=qianfan") })
    }

    @Test("Row 5: only a Gemini key: no GLM request")
    func onlyGemini() async {
        let glm = FakeBackend(.answer("x"))
        let c = VisionChain([
            VisionBackend(.glm, hasKey: { false }, port: glm),
            VisionBackend(.gemini, hasKey: { true }, port: FakeBackend(.answer("gemini"))),
        ], clock: ManualClock())
        #expect(await c.ask("q", image: image) == .answer("gemini"))
        #expect(glm.count == 0)
    }

    @Test("Row 6: no vision key at all: NOT_CONFIGURED")
    func none() async {
        let c = chain(glm: nil, gemini: nil, qianfan: nil)
        #expect(await c.ask("q", image: image) == .notConfigured)
        let r = await CameraQuestionHandler(camera: Camera(), vision: c, clock: ManualClock()).ask("q")
        #expect(r.code == .notConfigured)
    }

    @Test("Row 7: GLM 401 then Gemini answers; GLM 401 then Gemini 503 is busy (busy wins over auth)")
    func authThenOther() async {
        #expect(await chain(glm: FakeBackend(.authFailed, status: "401"), gemini: FakeBackend(.answer("ok")),
                            qianfan: nil).ask("q", image: image) == .answer("ok"))
        #expect(await chain(glm: FakeBackend(.authFailed, status: "401"), gemini: FakeBackend(.busy, status: "503"),
                            qianfan: nil).ask("q", image: image) == .busy)
        #expect(await chain(glm: FakeBackend(.authFailed, status: "401"), gemini: FakeBackend(.failed),
                            qianfan: nil).ask("q", image: image) == .authFailed)
        #expect(await chain(glm: FakeBackend(.failed), gemini: nil, qianfan: nil).ask("q", image: image) == .failed)
    }

    @Test("Row 3/item 4: VISION_FAILED advice no longer says 没看清楚")
    func failedAdvice() async {
        let r = await CameraQuestionHandler(camera: Camera(), vision: chain(glm: FakeBackend(.failed), gemini: nil,
                                                                             qianfan: nil),
                                            clock: ManualClock()).ask("q")
        #expect(r.code == .visionFailed)
        #expect(r.advice?.hasPrefix("这次看图没有成功") == true)
    }

    @Test("Row 11: logs carry no image bytes, question, answer text or key")
    func logsArePrivate() async {
        let lines = Lines()
        let c = chain(glm: FakeBackend(.busy, status: "503"), gemini: FakeBackend(.answer("前面有一辆秘密卡车")),
                      qianfan: nil, lines: lines)
        _ = await c.ask("前面那是什么问题文本", image: image)
        #expect(!lines.list.isEmpty)
        for line in lines.list {
            #expect(!line.contains("秘密卡车") && !line.contains("问题文本") && !line.contains("/9j")
                    && !line.contains("Bearer"))
        }
    }
}
