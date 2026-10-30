import Foundation
import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaAsrSherpa

/// Pure logic of the adapter (manifest, utterance bookkeeping, sample conversion, keyword tuning). These files build
/// without the sherpa-onnx binaries; decoding itself is checked on the device (F-05a §12 rows 1, 5–9).
struct SherpaLogicTests {
    private func dir(_ files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sherpa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: url.appendingPathComponent(name)) }
        return url
    }

    @Test func ctcManifestLoads() throws {
        let url = try dir([
            "asr.json": #"{"name": "zipformer-ctc", "type": "ctc", "model": "m.onnx", "tokens": "tokens.txt"}"#,
            "m.onnx": "x", "tokens.txt": "x",
        ])
        let m = try SherpaModelManifest.load(from: url, file: SherpaModelManifest.asrFile)
        #expect(m.name == "zipformer-ctc")
        #expect(try m.modelFiles() == .ctc(model: "m.onnx", tokens: "tokens.txt"))
    }

    @Test func transducerManifestNeedsAllFiles() throws {
        let json = #"{"name": "kws", "type": "transducer", "encoder": "e", "decoder": "d", "joiner": "j", "tokens": "t"}"#
        let url = try dir(["kws.json": json, "e": "", "d": "", "t": ""])
        #expect(throws: SherpaError.missingFile("j")) { try SherpaModelManifest.load(from: url, file: "kws.json") }
        let partial = try dir(["kws.json": #"{"name": "kws", "type": "transducer", "tokens": "t"}"#, "t": ""])
        #expect(throws: SherpaError.self) { try SherpaModelManifest.load(from: partial, file: "kws.json") }
    }

    @Test func badManifests() throws {
        #expect(throws: SherpaError.missingFile("asr.json")) { try SherpaModelManifest.load(from: try dir([:]), file: "asr.json") }
        let url = try dir(["asr.json": #"{"name": "x", "type": "whisper", "tokens": "t"}"#, "t": ""])
        #expect(throws: SherpaError.self) { try SherpaModelManifest.load(from: url, file: "asr.json") }
    }

    @Test func samplesAreScaledBy32768() {
        #expect(SampleConversion.floats([0, 16_384, -32_768, 32_767]) == [0, 0.5, -1, Float(32_767) / 32_768])
    }

    @Test func partialsOnlyWhenTextChanges() {
        var book = UtteranceBook()
        let id = UtteranceID(1)
        _ = book.begin(id, now: 0)
        let r1 = book.partial("", now: 1)
        #expect(r1 == nil)
        let r2 = book.partial("别", now: 100_000_000)
        #expect(r2 == .partial(id, "别"))
        let r3 = book.partial("别", now: 2)
        #expect(r3 == nil)
        let r4 = book.partial("别说", now: 3)
        #expect(r4 == .partial(id, "别说"))
    }

    @Test func finalAndMetrics() throws {
        var book = UtteranceBook()
        let id = UtteranceID(7)
        _ = book.begin(id, now: 1_000_000_000)
        book.fed(samples: 16_000)
        book.decoded(ns: 40_000_000)
        _ = book.partial("停", now: 1_300_000_000)
        let r5 = book.end(UtteranceID(6), now: 0)
        #expect(r5 == false)
        let r6 = book.end(id, now: 2_000_000_000)
        #expect(r6)
        let r7 = book.partial("停下", now: 2_000_000_001)
        #expect(r7 == nil)  // nothing after end but the final
        let finished = book.finish("停", now: 2_120_000_000)
        let (final, metrics) = try #require(finished)
        #expect(final == .final(id, "停"))
        #expect(metrics == SherpaUtteranceTiming(id: id, firstPartialMs: 300, finalMs: 120, audioMs: 1000, decodeMs: 40))
        #expect(!metrics.logLine.contains("停"))
        #expect(book.current == nil)
        let r8 = book.end(id, now: 3)
        #expect(r8 == false)  // a closed utterance gives nothing more
    }

    @Test func supersededUtteranceIsReplaced() {
        var book = UtteranceBook()
        _ = book.begin(UtteranceID(1), now: 0)
        _ = book.partial("别", now: 1)
        let r9 = book.begin(UtteranceID(2), now: 2)
        #expect(r9 == UtteranceID(1))
        let r10 = book.end(UtteranceID(1), now: 3)
        #expect(r10 == false)
        let r11 = book.partial("别", now: 4)
        #expect(r11 == .partial(UtteranceID(2), "别"))  // fresh text state
    }

    @Test func keywordsGetPerPhraseTuning() {
        let lines = Tuning.tuned(StopPhrases.keywordsFile).split(separator: "\n")
        #expect(lines.count == StopPhrases.all.count)
        #expect(Tuning.thresholds.count == StopPhrases.all.count && Tuning.boosts.count == StopPhrases.all.count)
        #expect(lines[0] == "b ié sh uō l e :\(Tuning.boosts[0]) #\(Tuning.thresholds[0]) @0")
        #expect(lines[3].hasSuffix("@3"))
        #expect(Tuning.tuned("x y @label\n") == "x y @label\n")
    }

    @Test func hitLabelsMapToPhrases() {
        #expect(KeywordLabel.phrase("0") == 0)
        #expect(KeywordLabel.phrase("@6") == 6)
        #expect(KeywordLabel.phrase("7") == nil)
        #expect(KeywordLabel.phrase("别说了") == nil)
    }
}
