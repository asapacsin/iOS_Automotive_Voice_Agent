import Testing
import NovaKit
import NovaPorts
@testable import NovaNav

@Suite("T-046i F-18 §21 item 1 the current destination")
struct CurrentDestinationTests {
    @Test("Row 1: only navigating (a list over guidance too) and arrived; the name cleaned and cut to 60")
    func phases() {
        var s = NavigationFlowState()
        s.destination = place("横琴文化艺术中心", 100)
        for phase: NovaNav.NavigationPhase in [.idle, .resolvingDestination, .awaitingDestinationSelection, .calculatingRoute,
                      .awaitingRouteSelection, .error] {
            s.phase = phase
            #expect(s.currentDestination == nil, "\(phase)")
        }
        s.phase = .navigating
        #expect(s.currentDestination == "横琴文化艺术中心")
        s.alongRouteList = true
        s.places = [place("加油站", 300)]
        #expect(s.currentDestination == "横琴文化艺术中心")
        s.phase = .arrived
        #expect(s.currentDestination == "横琴文化艺术中心")
        // After exit the flow resets: no destination.
        s = NavigationFlowState()
        #expect(s.currentDestination == nil)
        var odd = NavigationFlowState()
        odd.phase = .navigating
        odd.destination = place("「横琴」[文化]{中心}\n" + String(repeating: "长", count: 80), 1)
        let name = odd.currentDestination
        #expect(name?.hasPrefix("横琴文化中心") == true && name?.count == 60)
        #expect(!(name ?? "").contains { "「」[]{}\n".contains($0) })
    }
}
