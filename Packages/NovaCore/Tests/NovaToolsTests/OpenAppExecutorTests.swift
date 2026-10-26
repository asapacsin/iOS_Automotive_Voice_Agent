import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaTools

/// Switches to the asked surface unless `stuck`, and records each request.
final class FakeSurfaces: AppSurfacePort {
    let shown = Mutex<[AppSurface]>([])
    let stuck: Bool
    init(stuck: Bool = false) { self.stuck = stuck }
    func show(_ surface: AppSurface) async -> AppSurface? {
        shown.withLock { $0.append(surface) }
        return stuck ? nil : surface
    }
}

@Suite("F-25 open_app")
struct OpenAppExecutorTests {
    func call(_ app: String) -> ToolCall { ToolCall(id: CallID("c1")!, name: "open_app", arguments: ["app": .string(app)]) }

    @Test("F-25 open_app maps / settings switch the screen and report the switch read back")
    func switches() async {
        let surfaces = FakeSurfaces()
        for app in ["maps", "settings"] {
            let result = await OpenAppExecutor(surfaces: surfaces).execute(call(app))
            #expect(result.ok && result.data["app"] == .string(app))
        }
        #expect(surfaces.shown.withLock { $0 } == [.maps, .settings])
    }

    @Test("F-25 open_app: an unknown app is refused, a switch that did not happen is not claimed")
    func honest() async {
        let surfaces = FakeSurfaces(stuck: true)
        let unknown = await OpenAppExecutor(surfaces: surfaces).execute(call("wechat"))
        #expect(!unknown.ok && unknown.code == .appNotAllowed)
        #expect(surfaces.shown.withLock { $0.isEmpty })
        let stuck = await OpenAppExecutor(surfaces: surfaces).execute(call("maps"))
        #expect(!stuck.ok && stuck.code == .appNotOpened && stuck.advice != nil)
    }
}
