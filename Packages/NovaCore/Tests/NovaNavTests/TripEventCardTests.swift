import Foundation
import NovaPorts
import Testing
@testable import NovaNav

@Suite("T-046zg F-18 §43 item 4, §44 item 3 trip event card")
struct TripEventCardTests {
    private func card(_ event: TripEvent?) -> TripCard? {
        let place = Place(id: "p1", name: "横琴国际网球中心", address: nil,
                          coordinate: GeoCoordinate(latitude: 22.1, longitude: 113.5, datum: .gcj02), distanceMeters: nil,
                          city: "珠海市", photoURL: URL(string: "https://venue.example/v.jpg"))
        var stop = TripStop(index: 0, asked: "横琴国际网球中心", place: place, distanceMeters: nil)
        stop.event = event
        var list = TripList()
        list.arrange([stop])
        guard case .cards(let cards) = TripScreen.of(list, moving: false) else { return nil }
        return cards.first
    }

    @Test("T-046zg F-18 §44 row 91a/91b (card part): unconfirmed dates show 「日期未找到」; no picture shows 「未找到图片」 in the picture's place")
    func missing() throws {
        let c = try #require(card(TripEvent(title: "横琴AI嘉年华", start: "2026-11-28", end: "2026-11-29", datesFound: false,
                                            imageURL: nil, imageNote: "未找到图片")))
        #expect(c.event == "横琴AI嘉年华 · 日期未找到")
        #expect(c.photoURL == nil && c.imageNote == "未找到图片")
    }

    @Test("T-046zf F-18 §43 item 4 (card part): the event's picture replaces the venue photo; a searched picture is labelled 「网络图片」; an old plan keeps the venue photo")
    func picture() throws {
        let c = try #require(card(TripEvent(title: "横琴AI嘉年华", start: "2026-11-28", end: "2026-11-29", datesFound: true,
                                            imageURL: "https://i.example/p.jpg", imageNote: "网络图片")))
        #expect(c.photoURL == URL(string: "https://i.example/p.jpg") && c.imageNote == "网络图片")
        #expect(c.event == "横琴AI嘉年华 · 2026-11-28～2026-11-29")
        let old = try #require(card(TripEvent(title: "横琴AI嘉年华", start: "2026-11-28", end: "2026-11-29")))
        #expect(old.photoURL == URL(string: "https://venue.example/v.jpg") && old.imageNote == nil)
        let decoded = try JSONDecoder().decode(TripEvent.self, from: Data(#"{"title":"a","start":"2026-11-28","end":"2026-11-29"}"#.utf8))
        #expect(decoded.datesFound == nil && decoded.cardText == "a · 2026-11-28～2026-11-29")
    }
}
