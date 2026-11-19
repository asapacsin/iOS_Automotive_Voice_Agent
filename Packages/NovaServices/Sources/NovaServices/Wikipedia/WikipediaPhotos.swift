import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaNav
import NovaPorts

/// F-15b §46 items 1–3 (T-040r): a photo for a stop abroad from English Wikipedia (no key).
///
/// The English part of 「中文名 (English name)」 is searched (`w/rest.php/v1/search/page`, 3 results); each result's
/// `api/rest_v1/page/summary/<key>` is read in order, and the first page whose `coordinates` are within 2 km of the stop
/// and that has a secure `thumbnail.source` gives the link. No coordinates (a song, a film) or farther (a namesake)
/// → the next result. At most 1 search + 3 summaries, 5 s each, `User-Agent` as Wikimedia's API policy asks.
/// nil when no page fits; throws when the search cannot be reached (mainland China: fails fast, §46 item 5).
public final class WikipediaPhotos: PlacePhotoSource, @unchecked Sendable {
    public static let host = "https://en.wikipedia.org"
    public static let timeoutSeconds: Double = 5
    public static let results = 3
    public static let maxMeters: Double = 2_000
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func photo(asked: String, near: GeoCoordinate) async throws -> URL? {
        let query = PhotonPlaceSearch.split(asked).query
        // §46 item 1: only an English name is searched; a name with no Latin letters (租车, a Chinese-only name) asks nothing.
        guard query.unicodeScalars.contains(where: { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }) else { return nil }
        var components = URLComponents(string: Self.host + "/w/rest.php/v1/search/page")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(Self.results))]
        let found = try await get(components.url!)
        guard found.status == 200 else { throw AmapWebError.failed }
        for key in Self.keys(found.body).prefix(Self.results) {
            guard let encoded = key.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: Self.pathSegment),
                let url = URL(string: Self.host + "/api/rest_v1/page/summary/" + encoded) else { continue }
            let summary = try await get(url)
            guard summary.status == 200, let photo = Self.photo(summary.body, near: near) else { continue }
            return photo
        }
        return nil
    }

    private func get(_ url: URL) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("NovaDrive/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        do {
            return try await transport.send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw AmapWebError.timeout
        } catch {
            throw AmapWebError.failed
        }
    }

    static let pathSegment: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()

    /// The search results' page keys, in order.
    static func keys(_ body: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let pages = root["pages"] as? [[String: Any]] else { return [] }
        return pages.compactMap { ($0["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// The summary's thumbnail when its coordinates are within 2 km of `near`; nil otherwise.
    static func photo(_ body: Data, near: GeoCoordinate) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let at = root["coordinates"] as? [String: Any],
              let lat = (at["lat"] as? NSNumber)?.doubleValue, let lon = (at["lon"] as? NSNumber)?.doubleValue else { return nil }
        let page = GeoCoordinate(latitude: lat, longitude: lon, datum: .gcj02)
        guard PhotonPlaceSearch.meters(near, page) <= maxMeters else { return nil }
        return TripPhotoLink.secure((root["thumbnail"] as? [String: Any])?["source"] as? String)
    }
}
