import Testing
@testable import NovaKit
@testable import NovaTools

@Suite("F-20a §8 camera failures carry their spoken sentence")
struct CameraAdviceTests {
    @Test("Codes returned before the handler runs (window could not open) still have advice")
    func earlyReturnAdvice() {
        let denied = ToolDispatcher.failure(.cameraPermissionDenied)
        let busy = ToolDispatcher.failure(.cameraUnavailable)
        #expect(denied.advice?.hasPrefix("摄像头没有权限") == true)
        #expect(busy.advice?.hasPrefix("摄像头现在用不了") == true)
    }
}
