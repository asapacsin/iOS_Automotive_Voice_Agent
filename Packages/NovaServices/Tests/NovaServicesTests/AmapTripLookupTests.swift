import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

/// F-15b §68 (T-040zu): the 高德 request of a Macau lookup and the `info` of a refused one.
@Suite("T-040zu F-15b §68 高德 text search without the city limit, with its info")
struct AmapTripLookupTests {
    private func query(_ t: StubTransport) -> [String: String] {
        let items = t.requests.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("T-040zu F-15b §68 row 319: no city sends no city and no citylimit; each place keeps its adcode")
    func row319Request() async throws {
        let t = StubTransport()
        t.body = Data(#"{"status":"1","info":"OK","pois":[{"id":"B1","name":"大三巴牌坊","location":"113.540,22.197","adcode":"820002","cityname":"澳门特别行政区"}]}"#.utf8)
        let client = AmapWebClient(key: { "k" }, transport: t)
        let places = try await client.textInfo("大三巴牌坊", city: nil, cityLimit: false)
        #expect(places.first?.adcode == "820002")
        #expect(query(t)["city"] == nil && query(t)["citylimit"] == nil && query(t)["keywords"] == "大三巴牌坊")
        // row 320: a city as today.
        _ = try await client.textInfo("珠海渔女", city: "珠海", cityLimit: true)
        #expect(query(t)["city"] == "珠海" && query(t)["citylimit"] == "true")
    }

    @Test("T-040zu F-15b §68 row 322: a refused search throws its info")
    func row322Info() async {
        let t = StubTransport()
        t.body = Data(#"{"status":"0","info":"USER_ABROAD_DAILY_QUERY_OVER_LIMIT","infocode":"10045"}"#.utf8)
        let client = AmapWebClient(key: { "k" }, transport: t)
        do {
            _ = try await client.textInfo("大三巴牌坊", city: nil, cityLimit: false)
            Issue.record("no error")
        } catch let failure as AmapWebFailure {
            #expect(failure.info == "USER_ABROAD_DAILY_QUERY_OVER_LIMIT" && failure.isLimit)
        } catch {
            Issue.record("\(error)")
        }
        // The other entry points keep their plain errors.
        await #expect(throws: AmapWebError.quota) { try await client.text("x", city: nil) }
    }
}
