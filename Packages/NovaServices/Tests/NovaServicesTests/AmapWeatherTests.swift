import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaServices

/// Answers every request with one body and records the query.
final class WeatherBodyTransport: HTTPTransport, @unchecked Sendable {
    let body: String
    let urls = Mutex<[String]>([])
    init(_ body: String) { self.body = body }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        urls.withLock { $0.append(request.url?.absoluteString ?? "") }
        return (200, Data(body.utf8))
    }
}

