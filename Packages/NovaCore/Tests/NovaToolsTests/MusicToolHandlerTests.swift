import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

final class LanePlayer: MusicPort, @unchecked Sendable {
    let state = Mutex((playing: false, starts: true, stops: true))
    init(starts: Bool = true, stops: Bool = true) { state.withLock { $0.starts = starts; $0.stops = stops } }
    func playBundled() async -> Bool { state.withLock { $0.playing = $0.starts; return $0.starts } }
    func stop() async { state.withLock { if $0.stops { $0.playing = false } } }
    var isPlaying: Bool { get async { state.withLock { $0.playing } } }
}

final class FakeNamed: NamedMusicPort, @unchecked Sendable {
    let answer: NowPlaying?
    let queries = Mutex<[String]>([])
    init(_ answer: NowPlaying?) { self.answer = answer }
    func play(query: String) async throws { queries.withLock { $0.append(query) } }
    func nowPlaying() async -> NowPlaying? { answer }
}

private func call(_ name: String, _ args: [String: JSONValue]) -> ToolCall {
    ToolCall(id: CallID("m1")!, name: name, arguments: .object(args))
}

@Suite("T-032 F-13 music")
struct MusicToolHandlerTests {
    @Test("F-13 §10 row 1: bundled play and stop work offline and are read back from the player")
    func bundled() async {
        let music = LanePlayer()
        let h = MusicToolHandler(music: music, clock: ManualClock())
        let play = await h.execute(call("control_music", ["action": "play"]))
        #expect(play.ok && play.data["status"] == "playing")
        let stop = await h.execute(call("control_music", ["action": "stop"]))
        #expect(stop.ok && stop.data["status"] == "stopped")
    }

    @Test("F-13 §10 row 2: no success claim without verified playback")
    func noClaim() async {
        let h = MusicToolHandler(music: LanePlayer(starts: false), clock: ManualClock())
        #expect(await h.execute(call("control_music", ["action": "play"])).code == .notPlaying)
        let stuck = LanePlayer(stops: false)
        _ = await stuck.playBundled()
        let s = MusicToolHandler(music: stuck, clock: ManualClock())
        #expect(await s.execute(call("control_music", ["action": "stop"])).code == .musicStillPlaying)
    }

    @Test("F-13 play_music without Apple Music approval is an honest MUSIC_HANDOFF_UNAVAILABLE")
    func noHandoff() async {
        let h = MusicToolHandler(music: LanePlayer(), clock: ManualClock())
        #expect(await h.execute(call("play_music", ["title": "七里香"])).code == .musicHandoffUnavailable)
    }

    @Test("F-13 play_music reports only a verified now-playing; the rejected title is no evidence")
    func named() async {
        let named = FakeNamed(NowPlaying(title: "七里香", artist: "周杰伦"))
        let h = MusicToolHandler(music: LanePlayer(), named: named, clock: ManualClock())
        let ok = await h.execute(call("play_music", ["title": "七里香", "artist": "周杰伦"]))
        #expect(ok.ok && ok.data["now_playing"]?["title"] == "七里香")
        #expect(named.queries.withLock { $0 } == ["七里香 周杰伦"])

        let clock = ManualClock()
        let rejected = MusicToolHandler(music: LanePlayer(), named: named, clock: clock)
        let task = Task { await rejected.execute(call("play_music", ["query": "换一首", "exclude_title": "七里香"])) }
        for _ in 0..<40 {
            await Task.yield()
            clock.advance(by: .milliseconds(250))
        }
        let result = await task.value
        #expect(result.data["status"] == "requested_unverified")
    }
}

/// A named port that starts a preview which never plays and reports `failure` (T-032e).
final class FailingPreviewPort: NamedMusicPort, @unchecked Sendable {
    let failure: PreviewFailure?
    let stops = Mutex(0)
    init(_ failure: PreviewFailure?) { self.failure = failure }
    func play(query: String) async throws {}
    func play(_ request: NamedMusicRequest) async throws -> NamedMusicStart? {
        NamedMusicStart(album: nil, previewSeconds: 30, source: "itunes_preview")
    }
    func nowPlaying() async -> NowPlaying? { nil }
    func stop() async { stops.withLock { $0 += 1 } }
    var lastFailure: PreviewFailure? { get async { failure } }
}

@Suite("T-032e F-13 §17 honest NOT_PLAYING advice")
struct PreviewAdviceTests {
    /// The advice may forbid the words (「不要说版权或会员」) but never give them as the reason.
    static func givesNoRightsReason(_ advice: String) -> Bool {
        let reason = advice.replacingOccurrences(of: "不要说版权或会员", with: "")
        return !reason.contains("版权") && !reason.contains("会员")
    }

    @Test("T-032e row 8: each stage and nil maps to the item 7 advice; none gives 版权 or 会员 as the reason")
    func advice() {
        let network: [PreviewFailure?] = [.downloadTimeout, .downloadNetwork, .downloadHTTP(404), .tooLarge, .tooLong, nil]
        for f in network { #expect(PreviewAdvice.text(for: f) == "试听没放起来：网络太慢或者连不上。请如实说没放成，可以让用户稍后再试；不要说版权或会员。") }
        #expect(PreviewAdvice.text(for: .parse) == "试听没放起来：这首的试听文件放不了。请如实说没放成，可以换一首；不要说版权或会员。")
        #expect(PreviewAdvice.text(for: .engine) == "试听没放起来：手机的声音通道没准备好。请如实说没放成，可以再试一次；不要说版权或会员。")
        let all: [PreviewFailure?] = network + [.parse, .engine, .stopped]
        for f in all { #expect(Self.givesNoRightsReason(PreviewAdvice.text(for: f))) }
    }

    @Test("T-032e row 9: NOT_PLAYING carries the network, then the file advice; the bundled advice is unchanged")
    func handler() async throws {
        let tuning: MusicToolHandler.Tuning = { var t = MusicToolHandler.Tuning(); t.timeout = .milliseconds(20); t.poll = .milliseconds(5); return t }()
        for (failure, advice) in [(PreviewFailure.downloadTimeout, PreviewAdvice.network), (.parse, PreviewAdvice.file)] {
            let port = FailingPreviewPort(failure)
            let h = MusicToolHandler(music: LanePlayer(), named: port, clock: SystemClock(), tuning: tuning)
            let r = await h.execute(call("play_music", ["title": "oblivious", "artist": "Kalafina"]))
            #expect(!r.ok && r.code == .notPlaying && r.advice == advice)
            #expect(port.stops.withLock { $0 } == 1)
        }
        let bundled = MusicToolHandler(music: LanePlayer(starts: false), clock: ManualClock())
        let r = await bundled.execute(call("control_music", ["action": "play"]))
        #expect(!r.ok && r.code == .notPlaying && r.advice == "内置音乐没有放起来。请如实说没放成，不要说正在播放。")
    }
}
