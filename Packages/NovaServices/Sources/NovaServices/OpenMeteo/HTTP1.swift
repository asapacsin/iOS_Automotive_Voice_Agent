import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// F-18 §30 item 1 (T-046s): the bytes of one HTTP/1.1 GET sent over the app's own TCP+TLS connection. No Network
/// import, so it is unit-tested on Linux. The connection itself is `TCPHTTPFetcher` (NovaPlatform, the one package
/// `scripts/gates/check_imports.py` lets import Network).
public enum HTTP1Request {
    /// `GET <path>?<query> HTTP/1.1` with `Host`, `Accept`, `Accept-Encoding: identity`, `Connection: close` and
    /// `User-Agent`. Nil when the URL has no host. The query is sent as it is in the URL (already percent-encoded).
    public static func bytes(for url: URL) -> Data? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? url.path
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery { target += "?" + query }
        let lines = ["GET \(target) HTTP/1.1", "Host: \(host)", "Accept: application/json", "Accept-Encoding: identity",
                     "Connection: close", "User-Agent: NovaDrive"]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

/// F-18 §30 item 2 (T-046s): reads the whole answer the server sent before closing the connection.
public enum HTTP1Response {
    /// The status and body. The body comes from `Content-Length`, or `Transfer-Encoding: chunked`, or else is
    /// everything after the headers (read to close). Malformed or cut-short data is nil.
    public static func parse(_ data: Data) -> (status: Int, body: Data)? {
        let bytes = [UInt8](data)
        guard let end = find([13, 10, 13, 10], in: bytes, from: 0) else { return nil }
        guard let head = String(bytes: bytes[0..<end], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), status[1].count == 3, let code = Int(status[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = Array(bytes[(end + 4)...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let body = dechunk(rest) else { return nil }
            return (code, body)
        }
        if let length = headers["content-length"] {
            guard let n = Int(length), n >= 0, rest.count >= n else { return nil }
            return (code, Data(rest[0..<n]))
        }
        return (code, Data(rest))
    }

    static func dechunk(_ bytes: [UInt8]) -> Data? {
        var out = Data(), i = 0
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: i),
                  let sizeLine = String(bytes: bytes[i..<lineEnd], encoding: .ascii) else { return nil }
            let hex = sizeLine.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(hex, radix: 16), size >= 0 else { return nil }
            i = lineEnd + 2
            if size == 0 { return out }
            guard bytes.count >= i + size + 2, bytes[i + size] == 13, bytes[i + size + 1] == 10 else { return nil }
            out.append(contentsOf: bytes[i..<(i + size)])
            i += size + 2
        }
    }

    static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        for i in start...(bytes.count - needle.count) where Array(bytes[i..<(i + needle.count)]) == needle { return i }
        return nil
    }
}

/// F-18 §30 items 1, 3 (T-046s): an `HTTPTransport` that sends `HTTP1Request` bytes through a raw fetch (on the
/// phone `TCPHTTPFetcher`, NWConnection TCP+TLS, so QUIC cannot be chosen) and parses the answer with
/// `HTTP1Response`. The fetch throws `URLError(.timedOut)` or `URLError(.cannotConnectToHost)`; a reply that
/// cannot be read becomes `URLError(.badServerResponse)` (`ForecastError.failed`, not retried).
public struct RawHTTPTransport: HTTPTransport {
    public typealias Fetch = @Sendable (_ host: String, _ port: Int, _ request: Data, _ timeout: TimeInterval) async throws -> Data
    private let fetch: Fetch

    public init(fetch: @escaping Fetch) { self.fetch = fetch }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        guard let url = request.url, let host = url.host, let bytes = HTTP1Request.bytes(for: url) else {
            throw URLError(.badURL)
        }
        let raw = try await fetch(host, url.port ?? 443, bytes, request.timeoutInterval)
        guard let response = HTTP1Response.parse(raw) else { throw URLError(.badServerResponse) }
        return response
    }
}
