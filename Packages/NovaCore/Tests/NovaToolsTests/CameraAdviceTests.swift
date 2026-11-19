import Testing
@testable import NovaKit
@testable import NovaTools

@Suite("F-20a §8 camera failures carry their spoken sentence")
struct CameraAdviceTests {
    @Test("Codes returned before the handler runs (window could not open) still have advice")
    func earlyReturnAdvice() {
        let denied = ToolDispatcher.failure(.cameraPermissionDenied)
        let busy = ToolDispatcher.failure(.cameraUnavailable)
        // F-09b §13 item 6 (T-031o): rules, not a sentence; the app's screen line comes from the code.
        #expect(denied.data["next"]?.stringValue?.contains("不要描述画面") == true)
        #expect(CameraQuestionHandler.screenLine(denied)?.hasPrefix("摄像头没有权限") == true)
        #expect(CameraQuestionHandler.screenLine(busy)?.hasPrefix("摄像头现在用不了") == true)
    }
}
