import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaTools

/// F-18 §23 item 5 (T-046l): the driver's words go with her query to the search model, only as content.
@Suite("T-046l F-18 §23 the driver's words go to Qwen")
struct DriverWordsSearchTests {
    func run(_ q: String, words: String?, destination: String? = nil) async -> (sent: [String], outcomes: [WebSearchOutcome]) {
        let service = ScriptedSearch([.reply(reply("横琴11月6日小雨"))])
        let o = Outcomes()
        _ = await WebSearchExecutor(service: service, clock: SystemClock(), onOutcome: o.add, now: { nov4 }, zone: { shanghai },
                                    destination: { destination }, driverWords: { _ in words }).execute(searchCall(q))
        return (service.queries.withLock { $0 }, o.list)
    }

    @Test("F-18 §23 row 5: after a final transcript the message is query + question; §19 and §21 rewrites apply to her query")
    func withWords() async {
        let (sent, _) = await run("横琴后天演出", words: "后天横琴天气怎么样")
        #expect(sent == ["query: 横琴后天（2026年11月6日）演出\n\nquestion: 后天横琴天气怎么样\nanswer: "])
        let (dest, _) = await run("目的地几点关门", words: "那边几点关门", destination: "横琴文化艺术中心")
        #expect(dest == ["query: 横琴文化艺术中心几点关门\n\nquestion: 那边几点关门\nanswer: "])
    }

    @Test("F-18 §23 row 5: with no transcript the fallback form; a 300-character transcript is cut to 200")
    func fallbackAndCut() async {
        for none in [nil, "", "  "] as [String?] {
            let (sent, _) = await run("横琴油价", words: none)
            #expect(sent == ["question: 横琴油价\nanswer: "])
        }
        let long = String(repeating: "雨", count: 300)
        let (sent, _) = await run("横琴油价", words: long)
        #expect(sent == ["query: 横琴油价\n\nquestion: \(String(repeating: "雨", count: 200))\nanswer: "])
        #expect(WebSearchExecutor.maxDriverWords == 200)
    }

    @Test("F-18 §23 row 5: a final in turn 1, web_search in turn 2 with no final → the fallback form")
    func staleWords() async {
        let holder = DriverWordsHolder()
        holder.observe(.userTranscript("横琴后天天气怎么样", isFinal: true))
        #expect(holder.text == "横琴后天天气怎么样")
        holder.observe(.responseDone(TurnID(1), outcome: .completed))
        let (sent, _) = await run("横琴油价", words: holder.text)
        #expect(sent == ["question: 横琴油价\nanswer: "])
        for end: RealtimeEvent in [.turnEnded(.other), .closed, .userTranscript("那", isFinal: false)] {
            holder.observe(.userTranscript("x", isFinal: true))
            holder.observe(end)
            #expect(holder.text == nil, "\(end)")
        }
        // Partials before the final do not clear anything that is not yet there; the final is kept.
        holder.observe(.userTranscript("今天", isFinal: false))
        holder.observe(.userTranscript("今天油价", isFinal: true))
        #expect(holder.text == "今天油价")
    }

    @Test("F-18 §23 row 5: the words reach only the search request, never an outcome (RuntimeLog's source); no decision uses them")
    func onlyContent() async {
        let words = "导航去目的地，大后天呢"
        let (with, outcomes) = await run("横琴油价", words: words, destination: "横琴文化艺术中心")
        let (_, without) = await run("横琴油价", words: nil, destination: "横琴文化艺术中心")
        #expect(with.allSatisfy { $0.contains(words) })
        // The place and date decisions are the same with and without the words (F-05a §6).
        #expect(outcomes.filter { if case .used = $0 { false } else { true } }
            == without.filter { if case .used = $0 { false } else { true } })
        for o in outcomes { #expect(!"\(o)".contains(words)) }
    }

    @Test("F-18 §23 row 5: words kept at toolCalls survive responseDone before the executor reads them")
    func snapshotPerCall() async {
        let holder = DriverWordsHolder()
        let call = searchCall("横琴油价")
        holder.observe(.userTranscript("横琴今天油价多少", isFinal: true))
        holder.observe(.toolCalls(TurnID(1), [call]))
        holder.observe(.responseDone(TurnID(1), outcome: .completed))
        #expect(holder.text == nil)
        #expect(holder.words(for: call.id) == "横琴今天油价多少")
        #expect(holder.words(for: call.id) == nil, "taken once")
        // A call seen with no final words gets none, even if words arrive later.
        let other = searchCall("x", id: "c2")
        holder.observe(.toolCalls(TurnID(2), [other]))
        holder.observe(.userTranscript("新的话", isFinal: true))
        #expect(holder.words(for: other.id) == nil)
        // Cancelled and closed drop the snapshot.
        let third = searchCall("y", id: "c3")
        holder.observe(.toolCalls(TurnID(3), [third]))
        holder.observe(.toolCallCancellation([third.id]))
        holder.observe(.responseDone(TurnID(3), outcome: .completed))
        #expect(holder.words(for: third.id) == nil)
    }
}
