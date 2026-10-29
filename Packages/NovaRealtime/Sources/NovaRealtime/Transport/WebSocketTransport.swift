import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit

/// One open WebSocket. Production: `URLSessionWebSocketConnector`; tests: a scripted fake server.
public protocol WebSocketConnection: Sendable {
    func send(_ text: String) async throws
    /// Next frame; throws `WebSocketClosed` when the socket closes or fails.
    func receive() async throws -> Data
    func ping() async throws
    func close()
}

public protocol WebSocketConnector: Sendable {
    func open(_ request: URLRequest) async throws -> any WebSocketConnection
}

/// How a socket ended. `code` 1006 means no close frame arrived (network drop). `httpStatus` is set
/// when the upgrade itself was refused (no 101), e.g. 401/403 for a bad key.
public struct WebSocketClosed: Error, Sendable, Hashable {
    public let code: Int
    public let reason: String
    public let httpStatus: Int?
    public init(code: Int, reason: String, httpStatus: Int? = nil) {
        self.code = code
        self.reason = reason
        self.httpStatus = httpStatus
    }
}

public struct URLSessionWebSocketConnector: WebSocketConnector {
    private let session: URLSession

    public init(tuning: RealtimeTuning = RealtimeTuning()) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Double(tuning.connectTimeout.milliseconds) / 1000
        session = URLSession(configuration: config)
    }

    public func open(_ request: URLRequest) async throws -> any WebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) async throws {
        do { try await task.send(.string(text)) } catch { throw closed() }
    }

    func receive() async throws -> Data {
        let message: URLSessionWebSocketTask.Message
        do { message = try await task.receive() } catch { throw closed() }
        switch message {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: return Data()
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }

    private func closed() -> WebSocketClosed {
        let code = task.closeCode == .invalid ? 1006 : task.closeCode.rawValue
        let status = (task.response as? HTTPURLResponse)?.statusCode
        return WebSocketClosed(code: code, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "",
                               httpStatus: status == 101 ? nil : status)
    }
}
