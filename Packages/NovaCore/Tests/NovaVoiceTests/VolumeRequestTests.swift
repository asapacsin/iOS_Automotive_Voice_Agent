import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

/// F-13a §10 row 16 (T-032i): a volume request answered with 「我调不了」 and no tool call is corrected once.
@Suite("T-032i F-13a §10 volume requests in the claim checker")
struct VolumeRequestTests {
    @Test("Row 16: 「把音量调大」「你说话大声点」 (only new words) with no tool call get one actionAskedNoToolCall each")
    func refusalIsCorrected() {
        for utterance in ["把音量调大", "你说话大声点"] {
            var h = PipelineHarness()
            h.driver(utterance)
            h.say("我调不了。")
            h.close()
            h.advance(by: .seconds(60))
            #expect(h.corrections == [.actionAskedNoToolCall], "\(utterance)")
        }
    }

    @Test("Row 16: each new volume word is a request")
    func words() {
        for utterance in ["音量", "大声点", "小声一点", "声音调大", "调小"] {
            #expect(ClaimLexicon.asksForAction(utterance), "\(utterance)")
        }
    }
}
