import Foundation
import NovaKit
import NovaPorts
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// F-13 §14 item 2, §15 item 1 (T-032c): 设置 → 音乐 →「曲库地区」. 中国大陆 is gone: CN returns nothing.
public enum MusicCountry: String, Sendable, Hashable, CaseIterable {
    case hk = "HK", tw = "TW", jp = "JP", us = "US"

    public static let settingKey = "music_country"
    public static let `default` = MusicCountry.hk

    /// §15 item 1: no saved region, a saved CN or anything unknown is HK.
    public static func resolve(saved: String?) -> MusicCountry {
        saved.flatMap(MusicCountry.init(rawValue:)) ?? .default
    }

    public var label: String {
        switch self {
        case .jp: "日本"
        case .hk: "香港"
        case .tw: "台湾"
        case .us: "美国"
        }
    }
}

/// One song result of the iTunes Search API (performance-partners.apple.com/search-api).
public struct ITunesSong: Sendable, Hashable {
    public let trackName: String
    public let artistName: String?
    public let collectionName: String?
    public let previewURL: URL?
    public let trackViewURL: URL?
    public let artworkURL: URL?

    public init(trackName: String, artistName: String?, collectionName: String? = nil, previewURL: URL?,
                trackViewURL: URL? = nil, artworkURL: URL? = nil) {
        self.trackName = trackName
        self.artistName = artistName
        self.collectionName = collectionName
        self.previewURL = previewURL
        self.trackViewURL = trackViewURL
        self.artworkURL = artworkURL
    }
}

/// F-13 §14 item 7: what the overlay card shows while a preview plays.
public struct PreviewCard: Sendable, Hashable {
    public static let attribution = "30 秒试听 · provided courtesy of iTunes"
    public let title: String
    public let artist: String?
    public let artworkURL: URL?
    public let storeURL: URL?
}

/// F-13 §14 items 2–3: request and pick, pure.
public enum ITunesSearch {
    public static let host = "https://itunes.apple.com"
    public static let limit = 10
    public static let timeout = NovaDuration.seconds(5)

    /// §15 item 5: what the term was made of.
    public static func termKind(_ r: NamedMusicRequest) -> String {
        r.title == nil ? "other" : r.artist == nil ? "title" : "title+artist"
    }

    /// Item 2: `title artist`; without a title, the present ones of album_or_work, artist, query, mood.
    public static func term(_ r: NamedMusicRequest) -> String {
        let parts = r.title != nil ? [r.title, r.artist] : [r.albumOrWork, r.artist, r.query, r.mood]
        return parts.compactMap { $0 }.joined(separator: " ")
    }

    public static func request(_ r: NamedMusicRequest, country: MusicCountry) -> URLRequest {
        var c = URLComponents(string: host + "/search")!
        c.queryItems = [URLQueryItem(name: "term", value: term(r)), URLQueryItem(name: "country", value: country.rawValue),
                        URLQueryItem(name: "media", value: "music"), URLQueryItem(name: "entity", value: "song"),
                        URLQueryItem(name: "limit", value: String(limit))]
        var req = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: Double(timeout.milliseconds) / 1000)
        req.httpMethod = "GET"
        return req
    }

    /// Bad JSON throws; a body without results is `[]`.
    public static func songs(_ body: Data) throws -> [ITunesSong] {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw NamedMusicError.searchFailed
        }
        return ((root["results"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let name = r["trackName"] as? String else { return nil }
            func url(_ k: String) -> URL? { (r[k] as? String).flatMap(URL.init(string:)) }
            return ITunesSong(trackName: name, artistName: r["artistName"] as? String,
                              collectionName: r["collectionName"] as? String, previewURL: url("previewUrl"),
                              trackViewURL: url("trackViewUrl"), artworkURL: url("artworkUrl100"))
        }
    }

    /// Lower-cased, full-width ASCII (U+FF01–FF5E, U+3000) to half-width.
    public static func fold(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            switch u.value {
            case 0xFF01...0xFF5E: Unicode.Scalar(u.value - 0xFEE0)!
            case 0x3000: " "
            default: u
            }
        })).lowercased()
    }

    /// Item 3: index into `songs` of the pick, or nil.
    public static func pick(_ songs: [ITunesSong], for r: NamedMusicRequest) -> Int? {
        let exclude = r.excludeTitle.map(fold)
        let usable = songs.indices.filter { songs[$0].previewURL != nil && fold(songs[$0].trackName) != exclude }
        func matches(_ s: ITunesSong) -> Bool {
            let title = r.title.map { fold(s.trackName).contains(fold($0)) } ?? true
            let artist = r.artist.map { a in s.artistName.map { fold($0).contains(fold(a)) } ?? false } ?? true
            return title && artist
        }
        return usable.first { matches(songs[$0]) } ?? usable.first
    }

    /// Item 4: an `http://` preview is requested as `https://`.
    public static func secure(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = "https"
        return c.url ?? url
    }
}

/// Item 2: no HTTP cache at all.
public struct UncachedTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }
    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// F-13 §14 items 1–6, 10 (T-032b): named music as iTunes 30 s previews streamed in the app.
public final class ITunesPreviewMusic: NamedMusicPort, @unchecked Sendable {
    public static let previewSeconds = 30
    public static let source = "itunes_preview"

    private let transport: any HTTPTransport
    private let player: any PreviewPlayer
    private let clock: any NovaClock
    private let country: @Sendable () -> MusicCountry
    private let stopBundled: @Sendable () async -> Void
    private let log: @Sendable (String) -> Void
    private let onCard: @Sendable (PreviewCard?) -> Void
    private let current = Mutex<ITunesSong?>(nil)
    /// When the current preview was asked for; cleared once it is seen playing.
    private let askedAt = Mutex<NovaInstant?>(nil)

    public init(transport: any HTTPTransport = UncachedTransport(), player: any PreviewPlayer, clock: any NovaClock,
                country: @escaping @Sendable () -> MusicCountry, stopBundled: @escaping @Sendable () async -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in }, onCard: @escaping @Sendable (PreviewCard?) -> Void = { _ in }) {
        self.transport = transport
        self.player = player
        self.clock = clock
        self.country = country
        self.stopBundled = stopBundled
        self.log = log
        self.onCard = onCard
    }

    public func play(query: String) async throws {
        _ = try await play(NamedMusicRequest(query: query))
    }

    public func play(_ request: NamedMusicRequest) async throws -> NamedMusicStart? {
        let cc = country()
        let start = clock.now
        var (songs, picked) = try await search(request, country: cc, attempt: 1)
        // §15 item 3 (T-032c): title and artist found nothing usable: once more with the title alone.
        if picked == nil, request.title != nil, request.artist != nil {
            var titleOnly = request
            titleOnly.artist = nil
            (songs, picked) = try await search(titleOnly, country: cc, attempt: 2)
        }
        guard let picked, let preview = songs[picked].previewURL else { throw NamedMusicError.notFound }
        let song = songs[picked]
        // Item 4: a preview replaces the bundled track and any earlier preview.
        await stopBundled()
        await player.stop()
        current.withLock { $0 = song }
        askedAt.withLock { $0 = start }
        await player.play(ITunesSearch.secure(preview))
        return NamedMusicStart(album: song.collectionName, previewSeconds: Self.previewSeconds, source: Self.source)
    }

    /// One request and the §14 item 3 pick; logs `music search` with `try=` and `term=` (§15 item 5).
    private func search(_ request: NamedMusicRequest, country cc: MusicCountry,
                        attempt: Int) async throws -> ([ITunesSong], Int?) {
        let start = clock.now
        func line(_ results: Int, _ picked: Int?) -> String {
            "music search ms=\(Int(clock.now.milliseconds - start.milliseconds)) results=\(results) picked=\(picked.map(String.init) ?? "none") country=\(cc.rawValue) try=\(attempt) term=\(ITunesSearch.termKind(request))"
        }
        let songs: [ITunesSong]
        do {
            let (status, body) = try await transport.send(ITunesSearch.request(request, country: cc))
            guard (200..<300).contains(status) else { throw NamedMusicError.searchFailed }
            songs = try ITunesSearch.songs(body)
        } catch {
            log(line(0, nil))
            throw NamedMusicError.searchFailed
        }
        let picked = ITunesSearch.pick(songs, for: request)
        log(line(songs.count, picked))
        return (songs, picked)
    }

    /// Item 5: the picked song, only while the player is actually playing it.
    public func nowPlaying() async -> NowPlaying? {
        guard let song = current.withLock({ $0 }), await player.isPlaying else { return nil }
        // Item 10 and 7: the first time it is seen playing, log the time and show the card.
        if let asked = askedAt.withLock({ a in defer { a = nil }; return a }) {
            log("music preview playing ms=\(Int(clock.now.milliseconds - asked.milliseconds))")
            onCard(PreviewCard(title: song.trackName, artist: song.artistName, artworkURL: song.artworkURL,
                               storeURL: song.trackViewURL))
        }
        return NowPlaying(title: song.trackName, artist: song.artistName)
    }

    /// Item 7: the card for the playing preview, nil when nothing plays.
    public func card() async -> PreviewCard? {
        guard let song = current.withLock({ $0 }), await player.isPlaying else { return nil }
        return PreviewCard(title: song.trackName, artist: song.artistName, artworkURL: song.artworkURL, storeURL: song.trackViewURL)
    }

    /// Item 6: the player says the preview ended (or was stopped): nothing plays next, the card goes.
    public func ended() {
        askedAt.withLock { $0 = nil }
        guard current.withLock({ s in defer { s = nil }; return s != nil }) else { return }
        log("music preview ended")
        onCard(nil)
    }

    public func stop() async {
        await player.stop()
        ended()
    }

    public var isPlaying: Bool { get async { await player.isPlaying } }
}

/// F-13 §14 items 4, 6: `control_music` covers the preview too: stop stops both, playing means either.
public struct PreviewAwareMusic: MusicPort {
    private let base: any MusicPort
    private let preview: ITunesPreviewMusic
    public init(base: any MusicPort, preview: ITunesPreviewMusic) {
        self.base = base
        self.preview = preview
    }
    public func playBundled() async -> Bool {
        await preview.stop()
        return await base.playBundled()
    }
    public func stop() async {
        await preview.stop()
        await base.stop()
    }
    public var isPlaying: Bool { get async { let b = await base.isPlaying; let p = await preview.isPlaying; return b || p } }
}
