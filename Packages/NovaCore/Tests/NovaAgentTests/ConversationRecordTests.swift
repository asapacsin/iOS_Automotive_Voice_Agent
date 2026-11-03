import Foundation
import Synchronization
import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaPorts

final class MemoryWriter: RecordWriter, @unchecked Sendable {
    let lines = Mutex<[String]>([])
    let fail = Mutex(false)
    func append(_ new: [String]) throws {
        struct Failed: Error {}
        if fail.withLock({ $0 }) { throw Failed() }
        lines.withLock { $0 += new }
    }
}

private let header = RecordHeader(appVersion: "1.0(7)", comfortMode: "model", interruptible: false, speakingStyle: "default")

@Suite("T-031f F-12 §17 conversation record")
struct ConversationRecordTests {
    @Test("Row 1: one merged reply line per turn; outcomes judged after the turn ends, in the runtime's order")
    func lines() {
        var r = ConversationRecorder()
        var out: [String] = []
        let t1 = TurnID(1), t2 = TurnID(2), t3 = TurnID(3), t4 = TurnID(4), t5 = TurnID(5)
        out += r.add(.heardLocal("有点热"), atMs: 100)
        out += r.add(.utterance(id: 1, sent: true, mute: "none"), atMs: 110)
        out += r.add(.turnStarted(t1), atMs: 200)
        out += r.add(.toolCall(name: "control_climate", arguments: ["action": "adjust_temperature", "value": .int(-1)]), atMs: 210)
        out += r.add(.turnComplete(t1, outcome: "completed"), atMs: 215)
        out += r.add(.toolResult(name: "control_climate", ok: true, code: nil, data: ["temperature_c": .int(23)]), atMs: 220)
        // A claim held whole: text during the turn, released by the core only after responseDone.
        out += r.add(.turnStarted(t2), atMs: 300)
        out += r.add(.replyText(t2, "温度调低"), atMs: 310)
        out += r.add(.replyText(t2, "了一度。"), atMs: 320)
        out += r.add(.generationComplete(t2), atMs: 350)
        out += r.add(.turnComplete(t2, outcome: "completed"), atMs: 400)
        out += r.add(.spoke, atMs: 401)
        out += r.add(.playbackStarted, atMs: 410)
        // A claim voided when the turn closes; the correction then names the reason.
        out += r.add(.turnStarted(t3), atMs: 500)
        out += r.add(.replyText(t3, "车窗打开了。"), atMs: 510)
        out += r.add(.turnComplete(t3, outcome: "completed"), atMs: 530)
        out += r.add(.flushed, atMs: 531)
        out += r.add(.correction("UNVERIFIED_CLAIM"), atMs: 900)
        // Spoken while open (released); text with no responseStarted; then a close mid-turn.
        out += r.add(.turnStarted(t4), atMs: 1000)
        out += r.add(.replyText(t4, "好的。"), atMs: 1010)
        out += r.add(.spoke, atMs: 1011)
        out += r.add(.turnComplete(t4, outcome: "completed"), atMs: 1020)
        out += r.add(.replyText(t5, "我在"), atMs: 1100)
        out += r.add(.spoke, atMs: 1101)
        out += r.add(.session("closed"), atMs: 1200)
        out += r.finish(atMs: 1300)
        #expect(out == [
            "100 heard-local 有点热",
            "110 utterance id=1 sent=true mute=none",
            "210 tool-call control_climate {\"action\":\"adjust_temperature\",\"value\":-1}",
            "215 turn-end turnComplete turn=1 outcome=completed",
            "220 tool-result control_climate ok=true code=none {\"temperature_c\":23}",
            "300 reply-out turn=1 not-spoken",
            "350 turn-end generationComplete turn=2",
            "300 reply turn=2 温度调低了一度。",
            "400 turn-end turnComplete turn=2 outcome=completed",
            "410 playback started",
            "500 reply-out turn=2 held-released",
            "500 reply turn=3 车窗打开了。",
            "530 turn-end turnComplete turn=3 outcome=completed",
            "900 reply-out turn=3 voided reason=UNVERIFIED_CLAIM",
            "900 correction UNVERIFIED_CLAIM",
            "1000 reply turn=4 好的。",
            "1020 turn-end turnComplete turn=4 outcome=completed",
            "1100 reply-out turn=4 released",
            "1100 reply turn=5 我在",
            "1200 reply-out turn=5 released",
            "1200 session closed",
        ])
    }

    @Test("Row 2: with 51 files the oldest is deleted; other names are left alone")
    func retention() {
        let names = (0..<51).map { String(format: "20261103-%06d.txt", $0) } + ["notes.txt", "20261103.txt"]
        #expect(ConversationFiles.toDelete(names.shuffled()) == ["20261103-000000.txt"])
        #expect(ConversationFiles.toDelete(Array(names.prefix(50))).isEmpty)
        let utc = TimeZone(identifier: "UTC")!
        #expect(ConversationFiles.name(for: Date(timeIntervalSince1970: 0), timeZone: utc) == "19700101-000000.txt")
    }

    @Test("Row 3: a full queue writes dropped=<n>; a failed write stops the record without an error")
    func queue() {
        let record = ConversationRecord.make(enabled: true, header: header, capacity: 6)!
        let w = MemoryWriter()
        for i in 0..<5 { record.submit(.heardGemini("第\(i)句")) }
        record.drain(to: w)
        let written = w.lines.withLock { $0 }
        #expect(written.count == 4 + 2 + 1)
        #expect(written.last == "dropped=3")
        w.fail.withLock { $0 = true }
        record.submit(.session("closed"))
        record.drain(to: w)
        #expect(record.isStopped)
        w.fail.withLock { $0 = false }
        record.submit(.session("connected"))
        record.drain(to: w)
        #expect(w.lines.withLock { $0 }.count == written.count)
    }

    @Test("Row 4: setting off creates no record")
    func off() {
        #expect(ConversationRecord.make(enabled: false, header: header) == nil)
    }

    @Test("Row 5: first lines carry no key or instruction")
    func privacy() {
        let fake = ["AI", "za", "-not-a-real-value"].joined()
        let record = ConversationRecord.make(enabled: true, header: header)!
        // An event naming a stored key: only the name can appear; the record never reads the Keychain.
        record.submit(.toolCall(name: "set_speaking_style", arguments: ["style": "gemini_api_key"]))
        record.close()
        let w = MemoryWriter()
        record.drain(to: w)
        let text = w.lines.withLock { $0 }.joined(separator: "\n")
        #expect(text.hasPrefix("app 1.0(7)\ncomfortMode model\n可以打断她 off\nspeakingStyle default\n"))
        #expect(!text.contains(fake))
        #expect(!text.contains(PersonaInstruction.base.prefix(40)))
    }
}
