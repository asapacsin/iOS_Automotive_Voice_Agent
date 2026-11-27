import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

@Suite("T-020 F-07 clause segmenter and wait cues")
struct SegmenterTests {
    @Test("F-07 clauses cut at sentence ends, long-enough commas and 40 chars; first may be short")
    func segment() {
        var s = ClauseSegmenter()
        #expect(s.append("好的，") == ["好的，"])
        #expect(s.append("空调已经打开，温度") == [])
        #expect(s.append("调到二十二度了。") == ["空调已经打开，温度调到二十二度了。"])
        #expect(s.append(String(repeating: "啊", count: 40)) == [String(repeating: "啊", count: 40)])
        #expect(s.append("尾巴") == [] && s.flush() == "尾巴")
        #expect(s.append("。。") == [] && s.flush() == nil)
        s.reset()
        #expect(s.append("嗯，") == [])
    }

    @Test("F-07 placeholders are never read aloud")
    func speakable() {
        #expect(speakableText("<no speech>{pause}") == nil)
        #expect(speakableText(" 好的<break/>，{pause}马上 ") == "好的，马上")
    }

    @Test("F-07 wait cues at 3, 7 and 12 s, once each; a late wake says only the delay")
    func cues() {
        var t = WaitCueTurn()
        #expect(t.due(.seconds(2)) == nil)
        #expect(t.due(.seconds(3))?.code == .visual)
        #expect(t.due(.seconds(7)) == WaitCue(code: .progress, text: "收到，正在处理。"))
        #expect(t.due(.seconds(8)) == nil)
        #expect(t.due(.seconds(12))?.text == WaitCues.delay)
        var late = WaitCueTurn()
        _ = late.due(.seconds(13))
        #expect(late.due(.seconds(13))?.code == .delay)
        var quiet = WaitCueTurn()
        quiet.suspiciousAudio = true
        #expect(quiet.due(.seconds(20)) == nil)
        #expect(WaitCues.nextThreshold(after: .seconds(7)) == .seconds(12))
        #expect(WaitCues.toolPhrase("query_live_info") == "正在查询，稍等一下。")
    }
}
