import NovaKit
import NovaPorts
import NovaTools
import Testing

private final class BrokenCamera: CameraFrameSource {
    let error: CameraError?
    init(error: CameraError? = nil) { self.error = error }
    func captureStill() async throws -> JPEGImage {
        if let error { throw error }
        return JPEGImage(data: [0xFF, 0xD8])
    }
}

private struct OneAnswer: VisionPort {
    let answer: VisionAnswer
    func ask(_ question: String, image: JPEGImage) async -> VisionAnswer { answer }
}

private func values(_ value: JSONValue?) -> [String] {
    if case .array(let items)? = value { return items.compactMap(\.stringValue) }
    return []
}

@Suite("T-031m F-09b §13 stage 2: camera, music and open_app not-done results")
struct ToolReplyStage2ToolsTests {
    @Test("F-09b §13 row 5: camera failures carry claim_started, claim_done and describe_view; screen line kept")
    func camera() async {
        let clock = ManualClock()
        let cases: [(CameraQuestionHandler, ToolErrorCode, String)] = [
            (CameraQuestionHandler(camera: BrokenCamera(), vision: nil, clock: clock), .notConfigured, "看图功能还没有配置。"),
            (CameraQuestionHandler(camera: BrokenCamera(error: .permissionDenied), vision: OneAnswer(answer: .answer("x")),
                                   clock: clock), .cameraPermissionDenied, "摄像头没有权限，请在设置里允许。"),
            (CameraQuestionHandler(camera: BrokenCamera(error: .unavailable), vision: OneAnswer(answer: .answer("x")),
                                   clock: clock), .cameraUnavailable, "摄像头现在用不了。"),
            (CameraQuestionHandler(camera: BrokenCamera(), vision: OneAnswer(answer: .authFailed), clock: clock),
             .authFailed, "看图服务的密钥无效。"),
        ]
        for (handler, code, line) in cases {
            let r = await handler.ask("前面是什么")
            #expect(r.code == code && r.advice == nil && r.data["facts"]?["looked"] == .bool(false), "\(code)")
            let rules = values(r.data["must_not"])
            #expect(rules.contains("claim_started") && rules.contains("claim_done") && rules.contains("describe_view"))
            #expect(r.data["next"]?.stringValue?.contains("不要描述画面") == true)
            #expect(CameraQuestionHandler.screenLine(r) == line, "\(code)")
        }
    }

    @Test("F-09b §13 row 5: bundled music not playing and open_app not switched are not done")
    func musicAndApp() async {
        let music = await MusicToolHandler(music: LanePlayer(starts: false), clock: ManualClock())
            .execute(ToolCall(id: CallID("c1")!, name: "control_music", arguments: ["action": "play"]))
        #expect(music.code == .notPlaying && values(music.data["must_not"]).contains("claim_started"))
        #expect(values(music.data["must_not"]).contains("claim_done"))
        let app = await OpenAppExecutor(surfaces: FakeSurfaces(stuck: true))
            .execute(ToolCall(id: CallID("c1")!, name: "open_app", arguments: ["app": "maps"]))
        #expect(app.code == .appNotOpened && values(app.data["must_not"]) == ["claim_started", "claim_done"])
    }
}
