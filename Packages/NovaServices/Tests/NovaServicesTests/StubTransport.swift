import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NovaServices

/// A recording `HTTPTransport` for client tests.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    var status = 200
    var body = Data([1, 0, 2, 0, 9])
    var hang = false
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        requests.append(request)
        if hang { try await Task.sleep(for: .seconds(60)) }
        return (status, body)
    }
}
