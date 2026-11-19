import NovaKit
import Testing

@Suite("T-016o F-24 §17 connection notice")
struct ConnectionNoticeTests {
    private func t(_ ms: Int64) -> NovaInstant { NovaInstant(milliseconds: ms) }

    /// Every chip/line text from 0 to `until` in 100 ms steps, ticking where `nextChange` asks.
    private func texts(_ n: inout ConnectionNotice, from: Int64, to: Int64) -> [String] {
        var out: [String] = []
        var ms = from
        while ms <= to {
            _ = n.tick(at: t(ms))
            out.append(n.chipText(at: t(ms)) ?? n.line(notice: nil, at: t(ms)) ?? "")
            ms += 100
        }
        return out
    }

    @Test("F-24 §17 row 1: CONNECTION_CLOSED then setupComplete 600 ms later: no connection text")
    func quickReconnect() {
        var n = ConnectionNotice()
        _ = n.handle(.failed(retryable: true), at: t(0))
        for ms in stride(from: Int64(0), through: 500, by: 100) { #expect(n.chipText(at: t(ms)) == nil) }
        _ = n.handle(.setupComplete, at: t(600))
        for ms in stride(from: Int64(600), through: 8_000, by: 100) {
            #expect(n.chipText(at: t(ms)) == nil && n.line(notice: nil, at: t(ms)) == nil)
        }
    }

    @Test("F-24 §17 row 2: two retryable failures, setupComplete at 4.4 s: reconnecting 1–4.4 s, back 4.4–7.4 s")
    func resumeUnavailable() {
        var n = ConnectionNotice()
        _ = n.handle(.failed(retryable: true), at: t(0))
        _ = n.handle(.failed(retryable: true), at: t(2_000))
        #expect(n.chipText(at: t(900)) == nil)
        #expect(n.chipText(at: t(1_000)) == ConnectionNotice.reconnectingText)
        #expect(n.chipText(at: t(4_300)) == ConnectionNotice.reconnectingText)
        _ = n.handle(.setupComplete, at: t(4_400))
        #expect(n.chipText(at: t(4_400)) == ConnectionNotice.backText)
        #expect(n.chipText(at: t(7_399)) == ConnectionNotice.backText)
        #expect(n.nextChange(at: t(4_400)) == t(7_400))
        #expect(n.chipText(at: t(7_400)) == nil)
        #expect(n.chipText(at: t(20_000)) == nil)
    }

    @Test("F-24 §17 row 3: waiting for the network 0.5–3 s gives way to 等待网络…; row 2's end")
    func waitingWins() {
        var n = ConnectionNotice()
        _ = n.handle(.failed(retryable: true), at: t(0))
        _ = n.handle(.network(waiting: true), at: t(500))
        _ = n.handle(.failed(retryable: true), at: t(2_000))
        for ms in stride(from: Int64(500), through: 2_900, by: 100) { #expect(n.chipText(at: t(ms)) == nil) }
        _ = n.handle(.network(waiting: false), at: t(3_000))
        #expect(n.chipText(at: t(3_000)) == ConnectionNotice.reconnectingText)
        _ = n.handle(.setupComplete, at: t(4_400))
        #expect(n.chipText(at: t(4_400)) == ConnectionNotice.backText)
        #expect(n.chipText(at: t(7_400)) == nil)
    }

    @Test("F-24 §17 item 3: waiting the whole time: 已重新连接 is not shown")
    func neverShownNoBack() {
        var n = ConnectionNotice()
        _ = n.handle(.failed(retryable: true), at: t(0))
        _ = n.handle(.network(waiting: true), at: t(500))
        _ = n.handle(.network(waiting: false), at: t(3_000))
        _ = n.handle(.setupComplete, at: t(3_000))
        #expect(n.chipText(at: t(3_000)) == nil)
    }

    @Test("F-24 §17 row 4: giving up leaves the text to SessionEndedChip; no 重新连接中…")
    func gaveUp() {
        var n = ConnectionNotice()
        _ = n.handle(.failed(retryable: true), at: t(0))
        _ = n.handle(.gaveUp, at: t(60_000))
        let all = texts(&n, from: 60_000, to: 70_000)
        #expect(all.count == 101 && all.allSatisfy(\.isEmpty))
    }

    @Test("F-24 §17 row 5: AUTH: 连接失败，点按重试 kept until start; no code on screen")
    func nonRetryable() {
        var n = ConnectionNotice()
        _ = n.handle(.failed(retryable: false), at: t(0))
        _ = n.handle(.setupComplete, at: t(500))
        _ = n.handle(.failed(retryable: true), at: t(600))
        let all = texts(&n, from: 0, to: 30_000)
        #expect(all.count == 301 && all.allSatisfy { $0 == ConnectionNotice.failedText })
        #expect(n.chipText(at: t(30_000)) == nil)
        _ = n.handle(.stopped, at: t(31_000))
        #expect(n.line(notice: nil, at: t(31_000)) == nil)
        for text in [ConnectionNotice.reconnectingText, ConnectionNotice.backText, ConnectionNotice.failedText] {
            for code in ["AUTH", "CREDENTIAL", "QUOTA", "RATE_LIMITED", "MALFORMED", "INVALID_MODEL",
                         "CONNECTION_CLOSED", "RESUME_UNAVAILABLE", "连接错误"] {
                #expect(!text.contains(code))
            }
        }
    }

    @Test("F-24 §17 row 6: a camera notice is unchanged by a failure and reconnect")
    func cameraNoticeKept() {
        var n = ConnectionNotice()
        let camera = "摄像头现在用不了。"
        _ = n.handle(.failed(retryable: true), at: t(0))
        #expect(n.line(notice: camera, at: t(1_500)) == camera)
        _ = n.handle(.setupComplete, at: t(4_400))
        #expect(n.line(notice: camera, at: t(5_000)) == camera)
        _ = n.handle(.failed(retryable: false), at: t(9_000))
        #expect(n.line(notice: camera, at: t(9_000)) == camera)
        #expect(n.line(notice: nil, at: t(9_000)) == ConnectionNotice.failedText)
    }

    @Test("F-24 §17 row 7: connNotice log lines for rows 1, 2, 4, 5; no codes")
    func logLines() {
        var quick = ConnectionNotice()
        #expect(quick.handle(.failed(retryable: true), at: t(0)) == nil)
        #expect(quick.handle(.setupComplete, at: t(600)) == nil)

        var n = ConnectionNotice()
        var lines: [String] = []
        func add(_ l: String?) { if let l { lines.append(l) } }
        add(n.handle(.failed(retryable: true), at: t(0)))
        add(n.tick(at: t(1_000)))
        add(n.handle(.failed(retryable: true), at: t(2_000)))
        add(n.handle(.setupComplete, at: t(4_400)))
        add(n.tick(at: t(7_400)))
        #expect(lines == ["connNotice show=reconnecting ms=1000", "connNotice show=back ms=4400",
                          "connNotice show=none ms=7400"])

        var g = ConnectionNotice()
        _ = g.handle(.failed(retryable: true), at: t(0))
        _ = g.tick(at: t(1_000))
        #expect(g.handle(.gaveUp, at: t(60_000)) == "connNotice show=none ms=60000")

        var a = ConnectionNotice()
        let auth = a.handle(.failed(retryable: false), at: t(0))
        #expect(auth == "connNotice show=failed ms=0")
        #expect(!(auth ?? "").contains("AUTH"))
    }
}
