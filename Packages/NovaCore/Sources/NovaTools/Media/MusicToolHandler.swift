import NovaKit
import NovaPorts

/// F-13 music (T-032, `A/tools/MediaServer.kt`): `control_music` plays or stops the bundled track on the
/// media lane; `play_music` hands a description to Apple Music only when a `NamedMusicPort` exists
/// (OQ-IOS-7). Every result is read back from the player, never assumed: play is ok only when the
/// lane reports playing, stop only when it reports stopped (I-1, I-14).
public struct MusicToolHandler: ToolExecutor {
    public static let tools: Set<String> = ["control_music", "play_music"]

    public struct Tuning: Sendable, Hashable {
        /// Now-playing poll (F-13 §9).
        public var poll = NovaDuration.milliseconds(250)
        public var timeout = NovaDuration.seconds(6)
        public init() {}
    }

    private let music: any MusicPort
    private let named: (any NamedMusicPort)?
    private let clock: any NovaClock
    private let tuning: Tuning

    public init(music: any MusicPort, named: (any NamedMusicPort)? = nil, clock: any NovaClock,
                tuning: Tuning = Tuning()) {
        self.music = music
        self.named = named
        self.clock = clock
        self.tuning = tuning
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        switch call.name {
        case "control_music":
            switch call.arguments["action"]?.stringValue {
            case "play": return await playBundled()
            case "stop": return await stop()
            default: return ToolDispatcher.failure(.missingAction)
            }
        case "play_music":
            return await playNamed(call.arguments)
        default:
            return .failure(.unknownTool)
        }
    }

    private func playBundled() async -> ToolResult {
        guard await music.playBundled(), await music.isPlaying else {
            return .failure(.notPlaying, advice: "内置音乐没有放起来。请如实说没放成，不要说正在播放。")
        }
        return .success(["status": "playing", "source": "bundled",
                         "next": "说一句：音乐放起来了。"])
    }

    private func stop() async -> ToolResult {
        await music.stop()
        guard await !music.isPlaying else { return ToolDispatcher.failure(.musicStillPlaying) }
        return .success(["status": "stopped", "next": "说一句：音乐已关掉。"])
    }

    private func playNamed(_ args: JSONValue) async -> ToolResult {
        // iOS cannot drive other apps' players; only Apple Music via MusicKit, and only if approved.
        guard let named else { return ToolDispatcher.failure(.musicHandoffUnavailable) }
        let parts = ["title", "artist", "album_or_work", "query", "mood"].compactMap { args[$0]?.stringValue }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return .failure(.invalidFields, advice: "请用户说想听什么。") }
        let exclude = args["exclude_title"]?.stringValue
        // What played before the request is no evidence for it (music.md contract), unless it is the
        // very title asked for.
        let before = await named.nowPlaying()
        let wanted = args["title"]?.stringValue
        do {
            try await named.play(query: parts.joined(separator: " "))
        } catch {
            return ToolDispatcher.failure(.musicHandoffUnavailable)
        }
        // Poll now-playing every 250 ms for up to 6 s; only a track that is playing (and is not the one
        // the driver just rejected) is evidence.
        let deadline = clock.now + tuning.timeout
        while clock.now < deadline {
            if let playing = await named.nowPlaying(), playing.title != exclude,
               playing != before || playing.title == wanted {
                var nowPlaying: [String: JSONValue] = ["title": .string(playing.title)]
                if let artist = playing.artist { nowPlaying["artist"] = .string(artist) }
                return .success(["status": "playing", "now_playing": .object(nowPlaying),
                                 "next": "只按 now_playing 说正在放哪首。"])
            }
            do { try await clock.sleep(until: clock.now + tuning.poll) } catch { break }
        }
        return .success(["status": "requested_unverified",
                         "next": "只说一句：已经让音乐 app 去找了。不要说正在播放。"])
    }
}
