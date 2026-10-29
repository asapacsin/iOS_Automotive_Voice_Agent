import Testing
import NovaKit
@testable import NovaAgent

@Suite("T-062 F-23 background policy")
struct BackgroundPolicyTests {
    @Test("F-23 ios-architecture §11.3 table, row by row")
    func table() {
        for state in ListeningState.allCases {
            let fg = BackgroundDecision.decide(scene: .foreground, listening: state, navigating: false)
            #expect(fg.keepMic == nil && fg.keepSocket == nil && !fg.backgroundLocation && !fg.deactivateAudioSession)
            let nav = BackgroundDecision.decide(scene: .background, listening: state, navigating: true)
            #expect(nav.keepMic == true && nav.keepSocket == true && nav.backgroundLocation && !nav.forceDeepIdle)
        }
        for state in [ListeningState.active, .silentWait] {
            let d = BackgroundDecision.decide(scene: .background, listening: state, navigating: false)
            #expect(d.keepMic == true && d.keepSocket == true && !d.backgroundLocation)
        }
        let sleep = BackgroundDecision.decide(scene: .background, listening: .sleep, navigating: false)
        #expect(sleep.keepMic == false && sleep.keepSocket == false && sleep.forceDeepIdle && sleep.deactivateAudioSession)
        let deep = BackgroundDecision.decide(scene: .background, listening: .deepIdle, navigating: false)
        #expect(deep.keepMic == false && deep.keepSocket == false && !deep.forceDeepIdle && deep.deactivateAudioSession)
        let inactive = BackgroundDecision.decide(scene: .inactive, listening: .sleep, navigating: false)
        #expect(inactive.keepMic == nil)
    }
}
