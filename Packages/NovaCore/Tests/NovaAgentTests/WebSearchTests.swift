import Testing
import NovaKit
import NovaPorts
import NovaTools
import NovaVoice
@testable import NovaAgent

/// F-18 §15 (T-046c) rows 1-7, the parts in NovaCore. Setup JSON rows are in NovaRealtime's WebSearchCodecTests.
@Suite("T-046c F-18 §15 web search")
struct WebSearchTests {
    @Test("Rows 1-3: off equals today's instruction in both comfort modes; on swaps the sentence and drops 天气 from the strict list")
    func instruction() {
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            let base = PersonaInstruction.base(for: mode)
            #expect(PersonaInstruction.base(base, webSearch: false) == base)
            let on = PersonaInstruction.base(base, webSearch: true)
            #expect(on.contains(PersonaInstruction.webSearchSentence))
            #expect(on.contains("工具查不了或会变的信息（天气、新闻、营业时间、价格、比分等）：用 Google 搜索查"))
            #expect(!on.contains("现在查不了实时信息"))
            #expect(!on.contains("要去的地方、天气、路况"))
            #expect(on.contains("要去的地方、路况"))
            #expect(on.count <= PersonaInstruction.maxBaseCharacters, "\(mode) \(on.count)")
            // Only those two edits.
            #expect(on.replacingOccurrences(of: PersonaInstruction.webSearchSentence, with: PersonaInstruction.noLiveInfoSentence)
                .replacingOccurrences(of: "要去的地方、路况", with: "要去的地方、天气、路况") == base)
        }
        // The comfort test builds its session from today's base and SessionConfig's default (row 3).
        #expect(SessionConfig(systemInstruction: "x", tools: []).webSearch == false)
    }

    @Test("Row 4: a search event sends nothing to the provider and speaks nothing; only webSearchUsed is logged")
    func searchEvent() {
        var d = Drive()
        d.connect()
        let out = d.realtime(.webSearchUsed(query: "后天上海天气"))
        #expect(out == [.diagnostic(.webSearchUsed)])
    }

    @Test("Row 5: google_search as a function call is UNKNOWN_TOOL, nothing runs, webSearchAsFunction logged")
    func asFunction() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.userTranscript("搜一下", isFinal: true))
        d.realtime(.responseStarted(TurnID(1)))
        let call = ToolCall(id: CallID("call_g")!, name: "google_search", arguments: ["queries": ["x"]])
        let out = d.realtime(.toolCalls(TurnID(1), [call]))
        #expect(out.contains(.diagnostic(.webSearchAsFunction)))
        #expect(!out.contains { if case .startTool = $0 { true } else { false } })
        let responses = out.flatMap { e -> [ToolResponse] in if case .provider(.toolResponses(let r)) = e { r } else { [] } }
        #expect(responses.map(\.result.code) == [.unknownTool])
    }

    @Test("Row 6: no reply re-asks at 12 s with search on and 6 s off; give-up stays 4 s after the re-ask")
    func reask() {
        let on = TruthfulnessTuning.session(webSearch: true)
        #expect(on.emptyResponseReask == .seconds(12))
        #expect(on.emptyResponseGiveUp - on.emptyResponseReask == .seconds(4))
        #expect(TruthfulnessTuning.session(webSearch: false) == TruthfulnessTuning())
        for (tuning, at) in [(on, Int64(12_000)), (TruthfulnessTuning(), Int64(6_000))] {
            var p = DriverTurnPipeline(tuning: tuning)
            let out = p.handle(.driverUtterance("后天上海天气怎么样"), at: .zero)
            let reask = out.compactMap { o -> NovaInstant? in
                if case .schedule(let t, let when) = o, t.kind == .reask { when } else { nil }
            }
            #expect(reask == [NovaInstant.zero + .milliseconds(at)])
        }
    }

    @Test("Row 7: the record line has the query; the log event carries no words")
    func recordAndLog() {
        var r = ConversationRecorder()
        #expect(r.add(.search("后天上海天气"), atMs: 5) == ["5 search 后天上海天气"])
        #expect(DiagnosticEvent.webSearchUsed.kind == .webSearchUsed)
        #expect(String(describing: DiagnosticEvent.webSearchUsed) == "webSearchUsed")
    }
}
