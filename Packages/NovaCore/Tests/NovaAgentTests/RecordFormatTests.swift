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

    /// One event per kind, in a fixed order with fixed times. Fake text only (no real place or person).
    static let events: [RecordEvent] = [
        .session("connected"),
        .wakeToListening(ms: 420),
        .wakeUnused,
        .speakerCheck(SpeakerCheckLine(utterance: 1, kind: .speech, score: 0.81, threshold: 0.5, result: .accepted,
                                       speechMs: 900, scoreMs: 40, waitMs: 0)),
        .utterance(id: 1, sent: true, mute: "none"),
        .heardLocal("去测试路一号"),
        .heardGemini("去测试路一号"),
        .asrModelRemoved(bytes: 1024),
        .audio("route=speaker"),
        .contextNote(destination: "测试地点"),
        .nowNote(fields: [ContextNoteField.allCases[0]]),
        .screen(ScreenState(on: [.routePicking], musicVolume: 6)),
        .panel(.tripDetail, on: true, after: ScreenState(on: [.destinationList, .tripDetail])),
        .stateNote(StateNoteReason.allCases[0]),
        .summaryNote(exchanges: 3, ageS: 60),
        .turnStarted(t1),
        .toolCall(name: "web_search", arguments: ["query": "测试油价"]),
        .search("测试油价"),
        .searchExchange(WebSearchExchange(attempt: 1, requestBody: "{}", status: 200, ms: 800, bytes: 10,
                                          responseBody: "{}", error: nil, urlError: nil)),
        .searchOutcome(.used(ms: 800, attempts: 1, query: "测试油价", answer: "七块", sources: ["a.example"])),
        .toolResult(name: "web_search", ok: true, code: nil, data: ["answer": "七块"], elapsedMs: 800),
        .destSearch(DestinationSearchLine(destination: "测试地点", step: .around, count: 3, top: "测试地点一", score: 0.9,
                                          km: 1.5, check: .sure)),
        .replyText(t1, "七块。"),
        .languageLine(.correction),
        .held,
        .spoke,
        .flushed,
        .voiceClause(VoiceClauseLine(source: .qwen, chars: 3, firstMs: 300, ms: 600, attempt: 1)),
        .voiceFailed(VoiceFailedLine(turn: 1, source: .qwen, code: "QWEN_TTS_TIMEOUT")),
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
        .weather("ok"),
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
                                  agentLines: ["agentVersion 1.0.0", "agentHash 0123456789ab", "model gemini-3.8-live"])
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
    @Test("T-031u F-12 §21 row 1: a new record starts with recordFormat <n> (5 since T-040zj), then the app line with the commit")
    func row1() {
        let record = ConversationRecord.make(enabled: true, header: RecordHeader(
            appVersion: "0.1.0(1) abcdef0", comfortMode: "model", interruptible: false, speakingStyle: "default"))!
        let w = MemoryWriter()
        record.drain(to: w)
        let lines = w.lines.withLock { $0 }
        #expect(ConversationRecord.formatVersion == 5)
        #expect(Array(lines.prefix(2)) == ["recordFormat 5", "app 0.1.0(1) abcdef0"])
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
