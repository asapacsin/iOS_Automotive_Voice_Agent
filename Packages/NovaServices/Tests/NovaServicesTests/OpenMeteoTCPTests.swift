import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaServices

/// Answers in order; a URLError code is thrown, an Int is a status with a forecast body.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Step { case fail(URLError.Code), status(Int) }
    let steps: Mutex<[Step]>
    let sends = Mutex(0)
    init(_ steps: [Step]) { self.steps = Mutex(steps) }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        sends.withLock { $0 += 1 }
        #expect(request.timeoutInterval == 4)
        let step = steps.withLock { $0.removeFirst() }
        switch step {
        case .fail(let code): throw URLError(code)
        case .status(let s): return (s, Data(OpenMeteoClientTests.forecast.utf8))
        }
    }
}

@Suite("T-046s F-18 §30 Open-Meteo over TCP")
struct OpenMeteoTCPTests {
    @Test("T-046s F-18 §30 row 01: request bytes are GET path?query HTTP/1.1 with Host, identity and close")
    func requestBytes() throws {
        let url = "https://api.open-meteo.com/v1/forecast?latitude=35.69&longitude=139.69&current=temperature_2m,weather_code&timezone=auto&forecast_days=16"
        let text = String(decoding: try #require(HTTP1Request.bytes(for: URL(string: url)!)), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "GET /v1/forecast?latitude=35.69&longitude=139.69&current=temperature_2m,weather_code&timezone=auto&forecast_days=16 HTTP/1.1")
        #expect(Set(lines[1...5]) == ["Host: api.open-meteo.com", "Accept: application/json", "Accept-Encoding: identity",
                                      "Connection: close", "User-Agent: NovaDrive"])
        #expect(text.hasSuffix("\r\n\r\n") && lines.count == 8)
        let geo = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=%E4%B8%9C%E4%BA%AC&count=10")!
        let geoText = String(decoding: try #require(HTTP1Request.bytes(for: geo)), as: UTF8.self)
        #expect(geoText.hasPrefix("GET /v1/search?name=%E4%B8%9C%E4%BA%AC&count=10 HTTP/1.1\r\nHost: geocoding-api.open-meteo.com\r\n"))
    }

    @Test("T-046s F-18 §30 row 02: Content-Length, chunked, read to close, 503, truncated headers")
    func parse() {
        func r(_ s: String) -> (Int, String)? { HTTP1Response.parse(Data(s.utf8)).map { ($0.status, String(decoding: $0.body, as: UTF8.self)) } }
        let length = r("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}extra")
        #expect(length?.0 == 200 && length?.1 == "{\"a\":1}")
        let chunked = r("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n{\"a\r\n4;x=y\r\n\":1}\r\n0\r\n\r\n")
        #expect(chunked?.0 == 200 && chunked?.1 == "{\"a\":1}")
        let close = r("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"a\":1}")
        #expect(close?.0 == 200 && close?.1 == "{\"a\":1}")
        #expect(r("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n")?.0 == 503)
        #expect(r("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n") == nil)
        #expect(r("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n{\"a\":1}") == nil)
        #expect(r("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{\"a\"") == nil)
        #expect(r("garbage\r\n\r\n") == nil)
    }

    @Test("T-046s F-18 §30 row 03: a timeout then 200 returns the forecast after 2 sends; attempts=2")
    func retryThenOK() async throws {
        let t = ScriptedTransport([.fail(.timedOut), .status(200)])
        let attempts = ForecastAttempts()
        let f = try await ForecastAttempts.$current.withValue(attempts) {
            try await OpenMeteoClient(transport: t).dailyForecast(latitude: 35.69, longitude: 139.69)
        }
        #expect(f.days.count == 2 && t.sends.withLock { $0 } == 2 && attempts.last == 2)
    }

    @Test("T-046s F-18 §30 row 04: two timeouts are ForecastError.timeout after exactly 2 sends")
    func twoTimeouts() async {
        let t = ScriptedTransport([.fail(.timedOut), .fail(.timedOut), .status(200)])
        await #expect(throws: ForecastError.timeout) { try await OpenMeteoClient(transport: t).dailyForecast(latitude: 1, longitude: 2) }
        #expect(t.sends.withLock { $0 } == 2)
    }

    @Test("T-046s F-18 §30 row 05: cannotConnectToHost then 200 succeeds after 2 sends; 500 fails after 1 send")
    func connectFailureAndStatus() async throws {
        let t = ScriptedTransport([.fail(.cannotConnectToHost), .status(200)])
        _ = try await OpenMeteoClient(transport: t).lookUp("Tokyo", country: nil)
        #expect(t.sends.withLock { $0 } == 2)
        let bad = ScriptedTransport([.status(500), .status(200)])
        await #expect(throws: ForecastError.failed) { try await OpenMeteoClient(transport: bad).dailyForecast(latitude: 1, longitude: 2) }
        #expect(bad.sends.withLock { $0 } == 1)
        let attempts = ForecastAttempts()
        let once = ScriptedTransport([.status(200)])
        _ = try await ForecastAttempts.$current.withValue(attempts) { try await OpenMeteoClient(transport: once).dailyForecast(latitude: 1, longitude: 2) }
        #expect(attempts.last == 1)
    }

    @Test("T-046s F-18 §30 items 1, 2: RawHTTPTransport sends the request bytes to host:443 and parses the answer")
    func rawTransport() async throws {
        let seen = Mutex<[String]>([])
        let raw = RawHTTPTransport { host, port, request, timeout in
            seen.withLock { $0.append("\(host):\(port) \(timeout) " + String(decoding: request.prefix(13), as: UTF8.self)) }
            return Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        }
        var request = URLRequest(url: URL(string: "https://api.open-meteo.com/v1/forecast?x=1")!)
        request.timeoutInterval = 4
        let r = try await raw.send(request)
        #expect(r.status == 200 && r.body == Data("{}".utf8))
        #expect(seen.withLock { $0 } == ["api.open-meteo.com:443 4.0 GET /v1/forec"])
        let broken = RawHTTPTransport { _, _, _, _ in Data("nope".utf8) }
        await #expect(throws: URLError.self) { try await broken.send(request) }
    }
}
