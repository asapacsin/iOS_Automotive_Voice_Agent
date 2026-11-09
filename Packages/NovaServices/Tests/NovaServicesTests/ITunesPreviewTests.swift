import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
@testable import NovaServices
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers with a fixed status and body (or throws), keeping every request.
final class ScriptedHTTP: HTTPTransport, @unchecked Sendable {
    let status: Int
    let body: String
    let fails: Bool
    let sent = Mutex<[URLRequest]>([])
    init(status: Int = 200, body: String = #"{"results":[]}"#, fails: Bool = false) {
        self.status = status
        self.body = body
        self.fails = fails
    }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        sent.withLock { $0.append(request) }
        if fails { throw URLError(.timedOut) }
        return (status, Data(body.utf8))
    }
}

/// Reports playing `after` the play call (nil: never).
final class FakePreviewPlayer: PreviewPlayer, @unchecked Sendable {
    let after: Duration?
    let state = Mutex<(url: URL?, startedAt: ContinuousClock.Instant?, stops: Int)>((nil, nil, 0))
    init(after: Duration?) { self.after = after }
    func play(_ url: URL) async { state.withLock { $0.url = url; $0.startedAt = .now } }
    func stop() async { state.withLock { $0.startedAt = nil; $0.stops += 1 } }
    var isPlaying: Bool {
        get async {
            guard let after, let start = state.withLock({ $0.startedAt }) else { return false }
            return ContinuousClock.now - start >= after
        }
    }
}

final class Cards: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PreviewCard?] = []
    func add(_ c: PreviewCard?) { lock.withLock { items.append(c) } }
    var all: [PreviewCard?] { lock.withLock { items } }
}

final class Flag: @unchecked Sendable {
    let value = Mutex(0)
    func hit() { value.withLock { $0 += 1 } }
}

func song(_ name: String, _ artist: String, preview: String? = "https://audio.example/p.m4a") -> String {
    let p = preview.map { #","previewUrl":"\#($0)""# } ?? ""
    return #"{"trackName":"\#(name)","artistName":"\#(artist)","collectionName":"空の境界","trackViewUrl":"https://music.apple.com/x"\#(p)}"#
}

@Suite("T-032b F-13 §14 iTunes previews")
struct ITunesPreviewTests {
    static let fixture = #"{"resultCount":3,"results":["# + [song("oblivious", "Kalafina", preview: nil),
        song("oblivious (TV size)", "Other"), song("oblivious", "Kalafina")].joined(separator: ",") + "]}"

    static func port(_ http: ScriptedHTTP, _ player: FakePreviewPlayer, bundled: Flag = Flag(),
                     card: Cards? = nil) -> ITunesPreviewMusic {
        ITunesPreviewMusic(transport: http, player: player, clock: SystemClock(), country: { .cn },
                           stopBundled: { bundled.hit() }, onCard: { c in card?.add(c) })
    }

    static func handler(_ named: ITunesPreviewMusic, music: any MusicPort = NoMusic()) -> MusicToolHandler {
        var t = MusicToolHandler.Tuning()
        t.poll = .milliseconds(50)
        t.timeout = .milliseconds(900)
        return MusicToolHandler(music: music, named: named, clock: SystemClock(), tuning: t)
    }

    static func call(_ args: JSONValue) -> ToolCall { ToolCall(id: CallID("m")!, name: "play_music", arguments: args) }

    @Test("Row 1: term, country, media, entity, limit, no cache")
    func request() throws {
        let req = ITunesSearch.request(NamedMusicRequest(title: "oblivious", artist: "Kalafina"), country: .cn)
        let items = try #require(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(req.url!.absoluteString.hasPrefix("https://itunes.apple.com/search?"))
        #expect(items.map { "\($0.name)=\($0.value ?? "")" }
            == ["term=oblivious Kalafina", "country=CN", "media=music", "entity=song", "limit=10"])
        #expect(req.cachePolicy == .reloadIgnoringLocalCacheData && req.timeoutInterval == 5)
    }

    @Test("Row 2: no-preview result skipped; title and artist match picked; exclude_title gives the other")
    func pick() throws {
        let songs = try ITunesSearch.songs(Data(Self.fixture.utf8))
        #expect(ITunesSearch.pick(songs, for: NamedMusicRequest(title: "oblivious", artist: "Kalafina")) == 2)
        #expect(ITunesSearch.pick(songs, for: NamedMusicRequest(title: "oblivious", artist: "Kalafina",
                                                                excludeTitle: "oblivious")) == 1)
    }

    @Test("Row 3: terms without a title; only query; a full-width title matches")
    func terms() throws {
        #expect(ITunesSearch.term(NamedMusicRequest(artist: "梶浦由記", albumOrWork: "空の境界")) == "空の境界 梶浦由記")
        #expect(ITunesSearch.term(NamedMusicRequest(query: "很燃的片头曲")) == "很燃的片头曲")
        let songs = try ITunesSearch.songs(Data(Self.fixture.utf8))
        #expect(ITunesSearch.pick(songs, for: NamedMusicRequest(title: "ｏｂｌｉｖｉｏｕｓ", artist: "KALAFINA")) == 2)
    }

    @Test("Row 4: playing after 400 ms: ok with now_playing, 30 s preview, itunes_preview; bundled stopped; card shown")
    func plays() async {
        let bundled = Flag()
        let cards = Cards()
        let port = Self.port(ScriptedHTTP(body: Self.fixture), FakePreviewPlayer(after: .milliseconds(400)),
                             bundled: bundled, card: cards)
        let r = await Self.handler(port).execute(Self.call(["title": "oblivious", "artist": "Kalafina"]))
        #expect(r.ok)
        #expect(r.data["now_playing"] == ["title": "oblivious", "artist": "Kalafina"])
        #expect(r.data["preview_seconds"] == 30 && r.data["source"] == "itunes_preview" && r.data["album"] == "空の境界")
        #expect(r.data["next"] == .string(MusicToolHandler.previewNext))
        #expect(bundled.value.withLock { $0 } == 1)
        #expect(cards.all.compactMap { $0?.title } == ["oblivious"])
    }

    @Test("Row 5: HTTP 500 and timeout are MUSIC_SEARCH_FAILED, empty is MUSIC_NOT_FOUND, never playing is NOT_PLAYING")
    func failures() async {
        let args: JSONValue = ["title": "oblivious"]
        for http in [ScriptedHTTP(status: 500), ScriptedHTTP(fails: true), ScriptedHTTP(body: "not json")] {
            let r = await Self.handler(Self.port(http, FakePreviewPlayer(after: .zero))).execute(Self.call(args))
            #expect(!r.ok && r.code == ToolErrorCode.musicSearchFailed && r.advice != nil)
        }
        let empty = await Self.handler(Self.port(ScriptedHTTP(), FakePreviewPlayer(after: .zero))).execute(Self.call(args))
        #expect(!empty.ok && empty.code == ToolErrorCode.musicNotFound && empty.advice != nil)
        let silent = await Self.handler(Self.port(ScriptedHTTP(body: Self.fixture), FakePreviewPlayer(after: nil)))
            .execute(Self.call(args))
        #expect(!silent.ok && silent.code == ToolErrorCode.notPlaying)
        #expect(silent.data["status"] != "requested_unverified")
    }

    @Test("Row 6: control_music stop stops the preview; an ended preview leaves nothing playing and the card goes")
    func stopAndEnd() async throws {
        let player = FakePreviewPlayer(after: .zero)
        let cards = Cards()
        let port = Self.port(ScriptedHTTP(body: Self.fixture), player, card: cards)
        let music = PreviewAwareMusic(base: NoMusic(), preview: port)
        let tools = Self.handler(port, music: music)
        #expect(await tools.execute(Self.call(["title": "oblivious"])).ok)
        #expect(await music.isPlaying)
        let stop = await tools.execute(ToolCall(id: CallID("s")!, name: "control_music", arguments: ["action": "stop"]))
        #expect(stop.ok && stop.data["status"] == "stopped")
        #expect(await !music.isPlaying && cards.all.last == .some(nil))
        // Ended by itself: the player stops, the port forgets the song.
        #expect(await tools.execute(Self.call(["title": "oblivious"])).ok)
        await player.stop()
        port.ended()
        #expect(await port.nowPlaying() == nil && cards.all.last == .some(nil))
    }

    @Test("Row 7: an http preview URL is played from https")
    func https() async {
        let player = FakePreviewPlayer(after: .zero)
        let body = #"{"results":["# + song("x", "y", preview: "http://audio.example/p.m4a?a=1") + "]}"
        _ = try? await Self.port(ScriptedHTTP(body: body), player).play(NamedMusicRequest(title: "x"))
        #expect(player.state.withLock { $0.url }?.absoluteString == "https://audio.example/p.m4a?a=1")
    }

    @Test("Item 9: play_music description; item 10 log lines carry no song names")
    func textAndLog() async {
        let d = ToolCatalog.specs.first { $0.name == "play_music" }!.declaration.description
        #expect(d.contains("（播放 iTunes 30 秒试听）") && !d.contains("requested_unverified") && !d.contains("用手机音乐 app"))
        let lines = Mutex<[String]>([])
        let port = ITunesPreviewMusic(transport: ScriptedHTTP(body: Self.fixture), player: FakePreviewPlayer(after: .zero),
                                      clock: SystemClock(), country: { .jp }, stopBundled: {},
                                      log: { l in lines.withLock { $0.append(l) } })
        _ = try? await port.play(NamedMusicRequest(title: "oblivious", artist: "Kalafina"))
        _ = await port.nowPlaying()
        port.ended()
        let all = lines.withLock { $0 }
        #expect(all.count == 3)
        #expect(all[0].hasPrefix("music search ms=") && all[0].hasSuffix("results=3 picked=2 country=JP"))
        #expect(all[1].hasPrefix("music preview playing ms=") && all[2] == "music preview ended")
        #expect(!all.joined().contains("oblivious") && !all.joined().contains("Kalafina"))
    }
}

struct NoMusic: MusicPort {
    func playBundled() async -> Bool { false }
    func stop() async {}
    var isPlaying: Bool { get async { false } }
}
