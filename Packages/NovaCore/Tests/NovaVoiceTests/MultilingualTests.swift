import Testing
import NovaKit
import NovaPorts
@testable import NovaVoice

/// F-05a §14 (T-016l): Chinese, English and Japanese with a SenseVoice model downloaded after install.
@Suite("T-016l F-05a §14 multilingual final line")
struct MultilingualTests {
    static let model = MultilingualModel.files[0], tokens = MultilingualModel.files[1]

    @Test("T-016l F-05a §14 row 1: download: Wi-Fi start, progress, checked files installed; wrong SHA-256; Hugging Face fails")
    func row1() {
        var d = MultilingualDownload(installed: false)
        #expect(d.state == .missing && d.state.label == "未下载（约 240 MB）")
        let hf = "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/"
        #expect(d.switchOn(onWiFi: true) == [.fetch(url: hf + "model.int8.onnx", file: "model.int8.onnx", cellular: false)])
        d.progress(received: Self.model.bytes / 2)
        #expect(d.state == .downloading(percent: 49) && d.state.label == "下载中 49%")
        #expect(d.finished(size: Self.model.bytes, sha256: Self.model.sha256.uppercased())
                == [.install(file: "model.int8.onnx"), .fetch(url: hf + "tokens.txt", file: "tokens.txt", cellular: false)])
        #expect(d.finished(size: Self.tokens.bytes, sha256: Self.tokens.sha256) == [.install(file: "tokens.txt")])
        #expect(d.state == .ready && d.state.label == "已就绪" && MultilingualModel.folder == "sensevoice-2024-07-17")

        var bad = MultilingualDownload(installed: false)
        _ = bad.switchOn(onWiFi: true)
        #expect(bad.finished(size: Self.model.bytes, sha256: String(repeating: "0", count: 64)) == [.discard(file: "model.int8.onnx")])
        #expect(bad.state == .failed && bad.state.label == "下载失败，点按重试")
        #expect(bad.finished(size: Self.model.bytes, sha256: Self.model.sha256).isEmpty)  // nothing is installed after a failure
        var short = MultilingualDownload(installed: false)
        _ = short.switchOn(onWiFi: true)
        #expect(short.finished(size: Self.model.bytes - 1, sha256: Self.model.sha256) == [.discard(file: "model.int8.onnx")])

        var mirror = MultilingualDownload(installed: false)
        _ = mirror.switchOn(onWiFi: true)
        #expect(mirror.failed() == [.discard(file: "model.int8.onnx"),
                                    .fetch(url: "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx",
                                           file: "model.int8.onnx", cellular: false)])
        #expect(mirror.failed() == [.discard(file: "model.int8.onnx")] && mirror.state == .failed)
        #expect(mirror.retry(onWiFi: true).first == .fetch(url: hf + "model.int8.onnx", file: "model.int8.onnx", cellular: false))
        #expect(MultilingualDownload(installed: true).state == .ready)
    }

    @Test("T-016l F-05a §14 row 2: not on Wi-Fi, switch on, no tap: no download; 用流量下载 starts it")
    func row2() {
        var d = MultilingualDownload(installed: false)
        #expect(d.switchOn(onWiFi: false).isEmpty && d.state == .missing)
        #expect(d.useCellular() == [.fetch(url: MultilingualModel.url(host: "https://huggingface.co", file: "model.int8.onnx"),
                                           file: "model.int8.onnx", cellular: true)])
        var adopted = MultilingualDownload(installed: false)
        adopted.adopt(file: "tokens.txt", host: 1, cellular: false)
        #expect(adopted.state == .downloading(percent: 99) && adopted.hostIndex == 1)
        #expect(adopted.finished(size: Self.tokens.bytes, sha256: Self.tokens.sha256) == [.install(file: "tokens.txt")] && adopted.state == .ready)
        var ready = MultilingualDownload(installed: true)
        #expect(ready.useCellular().isEmpty)
        #expect(ready.delete() == [.removeAll] && ready.state == .missing)
    }

    @Test("T-016l F-05a §14 row 3: SenseVoice lang mapping, and its tags never reach the text")
    func row3() {
        #expect(["zh", "yue", "en", "ja", "ko", ""].map { SpokenLanguage(senseVoice: $0) } == [.zh, .zh, .en, .ja, .other, .other])
        #expect(SpokenLanguage(senseVoice: "<|en|>") == .en)
        #expect(SpokenLanguage.senseVoiceText("<|en|><|NEUTRAL|><|Speech|><|woitn|>What's the weather in Tokyo") == "What's the weather in Tokyo")
    }

    @Test("T-016l F-05a §14 row 4: SenseVoice at 500 ms wins; at 1,200 ms the streaming final is used; model not ready")
    func row4() {
        let id = UtteranceID(1)
        let t0 = NovaInstant(milliseconds: 1_000)
        var s = TranscriptSelector()
        _ = s.begin(id, localReady: true, multiReady: true)
        #expect(s.end(id, at: t0) == [.schedule(id, at: t0 + .milliseconds(800))])
        #expect(s.local(.final(id, "现在几点"), at: t0 + .milliseconds(100)).isEmpty)
        #expect(s.local(.final(id, "What time is it", language: .en), at: t0 + .milliseconds(500))
                == [.words(.final("What time is it", language: .en))])
        #expect(s.deadline(id, at: t0 + .milliseconds(800)).isEmpty)

        var late = TranscriptSelector()
        _ = late.begin(id, localReady: true, multiReady: true)
        _ = late.end(id, at: t0)
        _ = late.local(.final(id, "现在几点"), at: t0 + .milliseconds(100))
        #expect(late.deadline(id, at: t0 + .milliseconds(800)) == [.words(.final("现在几点"))])
        #expect(late.local(.final(id, "What time is it", language: .en), at: t0 + .milliseconds(1_200)).isEmpty)

        var plain = TranscriptSelector()
        _ = plain.begin(id, localReady: true, multiReady: false)
        _ = plain.end(id, at: t0)
        #expect(plain.local(.final(id, "现在几点"), at: t0 + .milliseconds(100)) == [.words(.final("现在几点"))])
    }

    @Test("T-016l F-05a §14 row 5: ScreenLanguage finals: English with language en; without it; Japanese; Korean; Russian")
    func row5() {
        #expect(ScreenLanguage.check("What's the weather in Tokyo", final: true, language: .en) == .show)
        #expect(ScreenLanguage.check("What's the weather in Tokyo", final: true) == .hide)
        #expect(ScreenLanguage.check("東京の天気は", final: true) == .show)
        #expect(ScreenLanguage.check("東京の天気は", final: false) == .wait)
        #expect(ScreenLanguage.check("안녕하세요", final: true) == .hide)
        #expect(ScreenLanguage.check("Привет", final: true) == .hide)
        #expect(ScreenLanguage.replyLanguage("Sure, it's 22 degrees") == .en && ScreenLanguage.replyLanguage("はい、22度です") == .ja)
        #expect(ScreenLanguage.replyLanguage("好的") == nil)
    }

    @Test("T-016l F-05a §14 row 6: isNotAllowed")
    func row6() {
        #expect(!ReplyLanguage.isNotAllowed("Sure, it's 22 degrees"))
        #expect(!ReplyLanguage.isNotAllowed("はい、22度です"))
        #expect(ReplyLanguage.isNotAllowed("안녕하세요"))
        #expect(!ReplyLanguage.isNotAllowed("Disculpa"))
    }
}
