import Foundation
import MusicKit
import NovaKit
import NovaPorts

public enum MusicKitError: Error, Sendable, Hashable { case notAuthorized, noMatch, noSubscription }

/// F-13 named music through Apple Music (T-072, OQ-IOS-7). Built but not wired until the OWNER
/// approves Apple Music only: `play_music` stays MUSIC_HANDOFF_UNAVAILABLE meanwhile. Now-playing is
/// read from the player's queue, never assumed (closes OQ-IOS-11 once a device run confirms it).
public final class MusicKitPlayer: NamedMusicPort, @unchecked Sendable {
    public init() {}

    public func play(query: String) async throws {
        guard await MusicAuthorization.request() == .authorized else { throw MusicKitError.notAuthorized }
        guard try await MusicSubscription.current.canPlayCatalogContent else { throw MusicKitError.noSubscription }
        var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
        request.limit = 1
        guard let song = try await request.response().songs.first else { throw MusicKitError.noMatch }
        let player = ApplicationMusicPlayer.shared
        player.queue = [song]
        try await player.play()
    }

    public func nowPlaying() async -> NowPlaying? {
        await MainActor.run {
            let player = ApplicationMusicPlayer.shared
            guard player.state.playbackStatus == .playing, let entry = player.queue.currentEntry else { return nil }
            return NowPlaying(title: entry.title, artist: entry.subtitle)
        }
    }
}
