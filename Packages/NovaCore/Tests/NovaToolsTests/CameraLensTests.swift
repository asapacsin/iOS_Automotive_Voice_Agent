import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// Two lenses; `select` can be held open by the test, and the rear lens can be broken.
private final class TwoLensCamera: CameraFrameSource {
    let rearBroken: Bool
    let gated: Bool
    let showing = Mutex(CameraLens.frontView)
    /// Each still records the lens it came from.
    let stills = Mutex<[CameraLens]>([])
    private let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)

    init(rearBroken: Bool = false, gated: Bool = false) {
        self.rearBroken = rearBroken
        self.gated = gated
    }

    func select(_ lens: CameraLens) async throws {
        if gated { await withCheckedContinuation { c in gate.withLock { $0 = c } } }
        if lens == .rearView && rearBroken { throw CameraError.unavailable }
        showing.withLock { $0 = lens }
    }

    func captureStill() async throws -> JPEGImage {
        let lens = showing.withLock { $0 }
        if lens == .rearView && rearBroken { throw CameraError.unavailable }
        stills.withLock { $0.append(lens) }
        return JPEGImage(data: [0xFF, 0xD8])
    }

    var selecting: Bool { gate.withLock { $0 != nil } }
    func finishSelect() { gate.withLock { c in defer { c = nil }; return c }?.resume() }
}

private final class GatedVision: VisionPort {
    private let gate = Mutex<CheckedContinuation<VisionAnswer, Never>?>(nil)
    func ask(_ question: String, image: JPEGImage) async -> VisionAnswer {
        await withCheckedContinuation { c in gate.withLock { $0 = c } }
    }
    var waiting: Bool { gate.withLock { $0 != nil } }
    func release(_ answer: VisionAnswer) { gate.withLock { c in defer { c = nil }; return c }?.resume(returning: answer) }
}

private struct FixedVision: VisionPort {
    func ask(_ question: String, image: JPEGImage) async -> VisionAnswer { .answer("一辆车。") }
}

private func until(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<2_000 where !condition() { await Task.yield() }
}

@Suite("T-071e F-20b rear view")
struct CameraLensTests {
    @Test("§10 row 3: 后面/后排/车里 → rear; 前面/路上 → front; neither or both → current")
    func chooser() {
        for q in ["后面是什么？", "后面有车吗？", "后排有人吗", "车里有人吗？"] {
            #expect(CameraLensChooser.choose(q, current: .frontView) == .rearView, "\(q)")
        }
        for q in ["前面是什么？", "路上有什么"] {
            #expect(CameraLensChooser.choose(q, current: .rearView) == .frontView, "\(q)")
        }
        for current in CameraLens.allCases {
            #expect(CameraLensChooser.choose("画面里有什么？", current: current) == current)
            #expect(CameraLensChooser.choose("前面和后面都有车吗", current: current) == current)
        }
    }

    @Test("§10 row 4: the result carries camera; a question naming 后面 switches first, one rear still")
    func resultCarriesCamera() async {
        let camera = TwoLensCamera()
        let lenses = Mutex<[CameraLens]>([])
        let handler = CameraQuestionHandler(camera: camera, vision: FixedVision(), clock: ManualClock(),
                                            lensChanged: { l in lenses.withLock { $0.append(l) } })
        let rear = await handler.execute(call("describe_camera_view", ["question": "后面是什么？"]))
        #expect(rear.data["camera"] == .string("rear_view"))
        #expect(camera.stills.withLock { $0 } == [.rearView])
        #expect(lenses.withLock { $0 } == [.rearView])
        let same = await handler.ask("画面里有什么？")
        #expect(same.data["camera"] == .string("rear_view"))
        let named = await handler.execute(call("describe_camera_view", ["question": "这是什么", "camera": "front_view"]))
        #expect(named.data["camera"] == .string("front_view"))
        #expect(await handler.lens == .frontView)
    }

    @Test("§10 row 4: a switch never cancels the question in flight")
    func switchKeepsQuestion() async {
        let camera = TwoLensCamera()
        let vision = GatedVision()
        let handler = CameraQuestionHandler(camera: camera, vision: vision, clock: ManualClock())
        async let answer = handler.ask("前面是什么")
        await until { vision.waiting }
        #expect(await handler.switchLens() == .rearView)
        vision.release(.answer("前面是一辆车。"))
        let r = await answer
        #expect(r.ok)
        #expect(r.data["camera"] == .string("front_view"))
        #expect(camera.stills.withLock { $0 } == [.frontView])
    }

    @Test("§10 row 4: a question during a switch waits for it, then captures from the new lens")
    func questionWaitsForSwitch() async {
        let camera = TwoLensCamera(gated: true)
        let handler = CameraQuestionHandler(camera: camera, vision: FixedVision(), clock: ManualClock())
        async let switched = handler.switchLens()
        await until { camera.selecting }
        #expect(await handler.switchLens() == nil)  // second tap while switching is ignored
        async let answer = handler.ask("画面里有什么？")
        for _ in 0..<50 { await Task.yield() }
        #expect(camera.stills.withLock { $0 }.isEmpty)
        camera.finishSelect()
        #expect(await switched == .rearView)
        let r = await answer
        #expect(r.data["camera"] == .string("rear_view"))
        #expect(camera.stills.withLock { $0 } == [.rearView])
    }

    @Test("A question cancelled while waiting for a switch never switches the lens")
    func cancelledQuestionKeepsLens() async {
        let camera = TwoLensCamera(gated: true)
        let handler = CameraQuestionHandler(camera: camera, vision: FixedVision(), clock: ManualClock())
        async let switched = handler.switchLens()
        await until { camera.selecting }
        async let answer = handler.ask("前面是什么？")
        for _ in 0..<50 { await Task.yield() }
        await handler.cancel()
        camera.finishSelect()
        #expect(await switched == .rearView)
        #expect(await answer.code == .superseded)
        #expect(await handler.lens == .rearView)
        #expect(camera.stills.withLock { $0 }.isEmpty)
    }

    @Test("§10 row 7: rear lens failure says 后面的摄像头现在用不了; 前方 still answers")
    func rearFailure() async {
        let camera = TwoLensCamera(rearBroken: true)
        let handler = CameraQuestionHandler(camera: camera, vision: FixedVision(), clock: ManualClock())
        let rear = await handler.ask("后面有车吗？")
        #expect(rear.code == .cameraUnavailable)
        #expect(rear.advice?.hasPrefix("后面的摄像头现在用不了。") == true)
        #expect(rear.data["answer"] == nil)
        #expect(await handler.lens == .frontView)
        #expect(await handler.switchLens() == nil)
        let front = await handler.ask("前面是什么？")
        #expect(front.ok)
        #expect(front.data["camera"] == .string("front_view"))
    }

    @Test("Catalog: camera is an optional enum; a value outside it is refused")
    func catalog() {
        let props = ToolCatalog.spec("describe_camera_view")?.declaration.parametersJSONSchema["properties"]
        #expect(props?["camera"]?["enum"] == .array(CameraLens.allCases.map { .string($0.rawValue) }))
        #expect(ToolCatalog.spec("describe_camera_view")?.declaration.description.contains("后面") == true)
        #expect(ToolCatalog.validate(call("describe_camera_view", ["question": "后面是什么"])) == nil)
        #expect(ToolCatalog.validate(call("describe_camera_view", ["question": "后面是什么", "camera": "rear_view"])) == nil)
        #expect(ToolCatalog.validate(call("describe_camera_view", ["question": "后面是什么", "camera": "back"]))
                == .invalidFieldValue)
        #expect(ToolCatalog.validate(call("describe_camera_view", ["camera": "rear_view"])) == .invalidFields)
    }
}
