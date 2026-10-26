import Testing
@testable import NovaAgent

@Suite("T-063 F-23 permissions on first need")
struct PermissionCoordinatorTests {
    @Test("F-23 §10 row 1 (logic): asked only at first need; a denial is explained with the way back")
    func firstNeed() {
        let needs: [(PermissionNeed, AppPermission)] = [(.firstTalk, .microphone), (.navigationOrWeatherHere, .location),
                                                        (.firstCall, .contacts), (.firstCameraQuestion, .camera)]
        for (need, permission) in needs {
            #expect(PermissionCoordinator.action(for: need, status: .notDetermined) == .request(permission))
            #expect(PermissionCoordinator.action(for: need, status: .granted) == .proceed)
            guard case .explain(let p, let message) = PermissionCoordinator.action(for: need, status: .denied) else {
                Issue.record("no explanation")
                continue
            }
            #expect(p == permission && message.contains("设置"))
        }
    }
}
