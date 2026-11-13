import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit

/// One HTTP exchange. Production: `URLSessionTransport`; tests: a recording stub. Moved out of the removed TTS
/// client unchanged (F-07 §17 item 1); the vision and weather clients use it.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(connectTimeout: NovaDuration = SpeechTuning().connectTimeout) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Double(connectTimeout.milliseconds) / 1000
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
