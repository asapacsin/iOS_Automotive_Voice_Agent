import Testing
import NovaKit
@testable import NovaAgent

@Suite("T-025 F-25 bubble fade (iOS values)")
struct BubbleFadeTests {
    func at(_ ms: Int64) -> NovaInstant { NovaInstant(milliseconds: ms) }

    @Test("F-25 bubble holds 4 s + 120 ms per character (max 10 s), then fades over 500 ms")
    func timing() {
        var bubble = BubbleFade()
        bubble.update("空调已打开", at: at(0))          // 5 chars → 4.6 s
        #expect(bubble.phase(at: at(4_599)) == .shown)
        #expect(bubble.phase(at: at(4_600)) == .fading)
        #expect(bubble.phase(at: at(5_100)) == .hidden)
        #expect(bubble.hold(for: String(repeating: "好", count: 200)) == .seconds(10))
    }

    @Test("F-25 a new exchange replaces the bubble at once and restarts the hold; empty hides at once")
    func replace() {
        var bubble = BubbleFade()
        bubble.update("你好", at: at(0))
        bubble.update("导航去珠海站", at: at(4_400))
        #expect(bubble.phase(at: at(5_000)) == .shown)
        bubble.update("", at: at(5_100))
        #expect(bubble.phase(at: at(5_100)) == .hidden)
    }

    @Test("F-25 bubble never fades while pinned (speaking); the hold restarts when unpinned")
    func pinned() {
        var bubble = BubbleFade()
        bubble.update("好的", at: at(0))
        bubble.pin(true, at: at(100))
        #expect(bubble.phase(at: at(60_000)) == .shown)
        bubble.pin(false, at: at(60_000))
        #expect(bubble.phase(at: at(64_239)) == .shown)
        #expect(bubble.phase(at: at(64_240)) == .fading)
    }
}
