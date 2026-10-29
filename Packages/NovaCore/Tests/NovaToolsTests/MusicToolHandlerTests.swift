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
