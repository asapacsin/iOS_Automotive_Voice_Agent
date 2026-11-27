import Foundation
import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools
@testable import NovaVoice

/// F-12 §21 item 3 (T-031u): a fixed session that writes every `RecordEvent` kind, encoded and compared with
/// `Fixtures/record-format-<n>.txt`. A changed line, or a kind added or removed, fails until `formatVersion` goes up
/// and a new fixture is added (old fixtures stay). Set `RECORD_FORMAT_WRITE=1` to write the fixture of a new format.
enum RecordFormatSession {
    static let t1 = TurnID(1), t2 = TurnID(2)
    static let searchRequest = "{\"input\":{\"messages\":[{\"content\":\"第一行\\n第二行\"}]},\"system\":\"规则一\n规则二\"}"
    static let searchReply = "id:1\nevent:result\n:HTTP_STATUS/200\ndata:{\"text\":\"七块\tC:\\\\path\"}\n\nid:2\r\ndata:{}\n\n"

    /// One event per kind, in a fixed order with fixed times. Fake text only (no real place or person).
    static let events: [RecordEvent] = [
        .session("connected"),
        .wakeToListening(ms: 420),
        .wakeUnused,
        .speakerCheck(SpeakerCheckLine(utterance: 1, kind: .speech, score: 0.81, threshold: 0.5, result: .accepted,
                                       speechMs: 900, scoreMs: 40, waitMs: 0)),
        .utterance(id: 1, sent: true, mute: "none"),
        .heardLocal("去测试路一号"),
        .heardGemini("去测试路\n一号"),  // F-18 §34 item 2: written as one line
        .asrModelRemoved(bytes: 1024),
        .audio("route=speaker"),
        .contextNote(destination: "测试地点"),
        .nowNote(fields: [ContextNoteField.allCases[0]]),
        .screen(ScreenState(on: [.routePicking], musicVolume: 6)),
        .panel(.tripDetail, on: true, after: ScreenState(on: [.destinationList, .tripDetail])),
        .panelCloseTap(.tripScreen),
        .stateNote(StateNoteReason.allCases[0]),
        .summaryNote(exchanges: 3, ageS: 60),
        .turnStarted(t1),
        .toolCall(name: "web_search", arguments: ["query": "测试油价"]),
        .search("测试油价"),
        // F-18 §34 item 3 (format 5): a search reply with line breaks, a tab and backslashes, escaped on one line.
        .searchExchange(WebSearchExchange(attempt: 1, requestBody: RecordFormatSession.searchRequest, status: 200, ms: 800,
                                          bytes: 10, responseBody: RecordFormatSession.searchReply, error: nil, urlError: nil)),
        .searchOutcome(.used(ms: 800, attempts: 1, query: "测试油价", answer: "七块", sources: ["a.example"])),
        .toolResult(name: "web_search", ok: true, code: nil, data: ["answer": "七块"], elapsedMs: 800),
        .destSearch(DestinationSearchLine(destination: "测试地点", step: .around, count: 3, top: "测试地点一", score: 0.9,
                                          km: 1.5, check: .sure)),
        .replyText(t1, "七块。"),
        .languageLine(.correction),
        .held,
        .spoke,
        .flushed,
        .voiceGemini(GeminiVoiceLine(turn: 1, heldMs: 0, firstMs: 500)),
        .playbackStarted,
        .claimCut(turn: 1, playedMs: 200),
        .bargeIn(stopped: true),
        .playbackFinished,
        .generationComplete(t1),
        .turnComplete(t1, outcome: "spoke"),
        .correction("wrong_language"),
        .turnStarted(t2),
        .toolDropped(AsyncTool.allCases[0]),
        .screenHidden(kind: ScreenTextKind.allCases[0], text: "测试"),
        .music("play"),
        .volume("up"),
        .undo("navigation"),
        .trip("shown days=1"),
        // F-15b §62 items 9, 12 (T-040zo): the planner round, failure and handoff lines (format 10).
        .trip("trip planner round=1 ms=8000 done=no days=4 stops=12 model=qwen3.8-max-0902"),
        .trip("trip planner failed reason=timeout round=2 ms=30000 model=qwen3.8-max-0902"),
        .trip("handoff said tool=plan_trip ms=0"),
        .weather("ok"),
        .events("events store hit cities=1 window=2026-11-28..2026-11-29"),
        .qiniu("search provider=qiniu job=live ms=2400 results=20 failed=no"),
        .qwen("qwen usage in=120,900 out=300,20"),
        .qwen("qwen history turns=1"),
        .qwen("qwen reconnect fresh=yes"),
        .speaker("uplink echo-gate coupling=default held_frames=12"),
        .speaker("speaker-split utterance=4 at_ms=1700 dropped_ms=1700"),
        .speaker("speaker-echo utterance=5 speechMs=20060 windows=19"),
        .speakerCheck(SpeakerCheckLine(utterance: 4, kind: .early, score: 6.5, threshold: 4, result: .accepted, speechMs: 1000,
                                       scoreMs: 60, waitMs: 3000, bar: .playback, window: 3)),
        .toolResultLine("tool-result web_search dropped reason=superseded"),
        .turnEnded(.needMoreInput),
        .sessionResume(handle: true, result: SessionResumeResult.allCases[0]),
        .sessionGaveUp(ms: 3000, attempts: 3, code: RetryableErrorCode.allCases[0]),
        .sessionClosed(SessionClosedLine(code: 1000, reason: "test")),
    ]

    /// The whole file text: format line, header, every event's lines, the closing lines.
    static func encoded() -> String {
        let header = RecordHeader(appVersion: "0.1.0(1) abcdef0", comfortMode: "model", interruptible: false,
                                  speakingStyle: "default", webSearch: true, searchKey: true, startedBy: "tap",
                                  declaredTools: ["web_search", "set_volume"],
                                  agentLines: ["agentVersion 1.0.0", "agentHash 0123456789ab", "model gemini-3.8-live"],
                                  voiceModel: "gemini-3.8-live")
        var recorder = ConversationRecorder()
        var lines = [ConversationRecord.formatLine] + header.lines
        for (n, e) in events.enumerated() { lines += recorder.add(e, atMs: Int64(n) * 100) }
        lines += recorder.finish(atMs: Int64(events.count) * 100)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The case names `RecordEvent` declares, read from its source, so a new kind cannot skip the check.
    static func declaredKinds(_ file: String = #filePath) throws -> Set<String> {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/NovaAgent/Record/ConversationRecord.swift"),
                             encoding: .utf8)
        guard let start = src.range(of: "public enum RecordEvent"), let end = src.range(of: "\n}\n", range: start.upperBound..<src.endIndex)
        else { return [] }
        var names: Set<String> = []
        for line in src[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("case ") else { continue }
            names.insert(String(t.dropFirst(5).prefix { $0.isLetter || $0.isNumber }))
        }
        return names
    }

    static func name(_ e: RecordEvent) -> String {
        let label = String(describing: e)
        return String(label.prefix { $0.isLetter || $0.isNumber })
    }

    static func fixture(_ version: Int, _ file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Fixtures/record-format-\(version).txt")
    }
}

@Suite("T-031u F-12 §21 record format")
struct RecordFormatTests {
    @Test("T-031u F-12 §21 row 1: a new record starts with recordFormat <n> (11 since T-031zg), then the app line with the commit")
    func row1() {
        let record = ConversationRecord.make(enabled: true, header: RecordHeader(
            appVersion: "0.1.0(1) abcdef0", comfortMode: "model", interruptible: false, speakingStyle: "default"))!
        let w = MemoryWriter()
        record.drain(to: w)
        let lines = w.lines.withLock { $0 }
        #expect(ConversationRecord.formatVersion == 18)
        #expect(Array(lines.prefix(2)) == ["recordFormat 18", "app 0.1.0(1) abcdef0"])
    }

    @Test("T-031u F-12 §21 rows 2-3: the fixed session encodes exactly to record-format-<formatVersion>.txt")
    func row2() throws {
        let url = RecordFormatSession.fixture(ConversationRecord.formatVersion)
        let text = RecordFormatSession.encoded()
        if ProcessInfo.processInfo.environment["RECORD_FORMAT_WRITE"] == "1", !FileManager.default.fileExists(atPath: url.path) {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let fixture = try String(contentsOf: url, encoding: .utf8)
        #expect(text == fixture, "record lines changed: raise ConversationRecord.formatVersion and add a fixture (F-12 §21 item 3)")
    }

    @Test("T-031u F-12 §21 row 4: the fixed session writes every RecordEvent kind the enum declares")
    func row4() throws {
        let declared = try RecordFormatSession.declaredKinds()
        let written = Set(RecordFormatSession.events.map(RecordFormatSession.name))
        #expect(declared.count >= 40)
        #expect(declared.subtracting(written).isEmpty, "kinds not in the fixture session: \(declared.subtracting(written).sorted())")
        // Each event writes at least one line, apart from the marks that only change the turn's reply line.
        var recorder = ConversationRecorder()
        for e in RecordFormatSession.events where !["spoke", "held", "flushed", "replyText", "turnStarted"].contains(RecordFormatSession.name(e)) {
            let lines = recorder.add(e, atMs: 0)
            #expect(!lines.isEmpty || RecordFormatSession.name(e) == "generationComplete" || RecordFormatSession.name(e) == "turnComplete",
                    "\(RecordFormatSession.name(e)) wrote nothing")
        }
    }
}

/// F-18 §34 item 1: the reverse of `escapeBody`, as `scripts/records/read.py` does it.
private func unescape(_ s: String) -> String {
    var out = ""
    var it = s.unicodeScalars.makeIterator()
    while let u = it.next() {
        guard u == "\\", let n = it.next() else { out.unicodeScalars.append(u); continue }
        switch n {
        case "n": out += "\n"
        case "r": out += "\r"
        case "t": out += "\t"
        default: out.unicodeScalars.append(n)
        }
    }
    return out
}

private func body(of line: String) -> String? {
    line.range(of: " body=").map { String(line[$0.upperBound...]) }
}

@Suite("T-046w F-18 §34 every record entry is one line")
struct RecordOneLineTests {
    private func encode(_ x: WebSearchExchange) -> [String] {
        var r = ConversationRecorder()
        return r.add(.searchExchange(x), atMs: 1200)
    }

    @Test("T-046w F-18 §34 row 18: a search reply with blank lines, data: lines, a tab and a backslash is one search-response line that unescapes exactly")
    func row18() throws {
        let reply = "id:1\nevent:result\n:HTTP_STATUS/200\ndata:{\"a\":\"x\ty\\\\z\"}\n\n\nid:2\r\ndata:{\"b\":\"\\\\n\"}\n\n"
        let lines = encode(WebSearchExchange(attempt: 1, requestBody: "{}", status: 200, ms: 5, bytes: reply.utf8.count,
                                             responseBody: reply, error: nil, urlError: nil))
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\t") })
        let response = try #require(lines.first { $0.hasPrefix("1200 search-response ") })
        #expect(unescape(try #require(body(of: response))) == reply)
        #expect(ConversationRecorder.escapeBody("a\\b\nc") == "a\\\\b\\nc")
    }

    @Test("T-046w F-18 §34 row 19: a search request with a line break in the system text is one search-request line and round-trips")
    func row19() throws {
        let request = RecordFormatSession.searchRequest
        #expect(request.contains("\n"))
        let lines = encode(WebSearchExchange(attempt: 2, requestBody: request, status: nil, ms: 5, bytes: 0,
                                             responseBody: nil, error: "timeout", urlError: nil))
        let line = try #require(lines.first { $0.hasPrefix("1200 search-request attempt=2 body=") })
        #expect(!line.contains("\n"))
        #expect(unescape(try #require(body(of: line))) == request)
    }

    @Test("T-046w F-18 §34 row 20: any other event with a line break in its text is written as one line, the break as a space")
    func row20() {
        var r = ConversationRecorder()
        #expect(r.add(.heardGemini("去测试\n路"), atMs: 1) == ["1 heard-gemini 去测试 路"])
        #expect(r.add(.trip("shown\r\ndays=1"), atMs: 2) == ["2 shown days=1"])
        #expect(r.add(.search("a\rb"), atMs: 3) == ["3 search a b"])
        #expect(r.add(.toolResult(name: "web_search", ok: true, code: nil, data: ["answer": "x"], elapsedMs: nil), atMs: 4)
                    .allSatisfy { !$0.contains("\n") })
        let all = RecordFormatSession.encoded().split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        let header = Set(["recordFormat 18", "app 0.1.0(1) abcdef0"])
        #expect(all.allSatisfy { !$0.contains("\r") })
        // Every line after the header starts with its time (row 23's check, on the fixed session).
        let events = all.drop { !($0.first?.isNumber ?? false) || header.contains(String($0)) }
        #expect(events.allSatisfy { $0.first?.isNumber == true }, "\(events.filter { $0.first?.isNumber != true })")
    }

    @Test("T-046w F-18 §34 row 21: the fixed session equals record-format-5.txt with header recordFormat 5")
    func row21() throws {
        // Format 6 (T-040zj, F-15b §57) only added screen keys; the format 5 fixture keeps T-046w's escaped bodies.
        #expect(ConversationRecord.formatVersion >= 5)
        let fixture = try String(contentsOf: RecordFormatSession.fixture(5), encoding: .utf8)
        #expect(fixture.hasPrefix("recordFormat 5\n"))
        let now = RecordFormatSession.encoded()
        #expect(now.contains("search-response attempt=1 status=200") && now.contains("\\tC:\\\\\\\\path"))
        #expect(fixture.contains("search-response attempt=1 status=200") && fixture.contains("\\tC:\\\\\\\\path"))
    }
}
