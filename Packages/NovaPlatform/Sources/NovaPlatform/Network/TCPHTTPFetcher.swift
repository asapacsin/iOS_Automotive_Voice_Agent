import Foundation
import Network

/// F-18 §30 item 1 (T-046s): one request over a connection the app opens itself, `NWParameters(tls:tcp:)`, so it is
/// TCP plus TLS and QUIC cannot be chosen. TLS uses the system trust and SNI for `host`; routing (VPN included) is
/// the phone's normal one. It sends `request`, reads until the server closes, then cancels. `timeout` covers
/// connect, TLS, send and the whole read: when it runs out the connection is cancelled and `URLError(.timedOut)` is
/// thrown. A connection or TLS failure throws `URLError(.cannotConnectToHost)`. No bytes are logged (I-8).
public enum TCPHTTPFetcher {
    static let maxBytes = 4 * 1024 * 1024

    public static func fetch(host: String, port: Int, request: Data, timeout: TimeInterval) async throws -> Data {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw URLError(.badURL) }
        // A host-name endpoint gives TLS its SNI and the system trust check for that name.
        let tls = NWProtocolTLS.Options()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        let queue = DispatchQueue(label: "novadrive.tcp-http")
        let done = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                done.set { result in
                    connection.cancel()
                    continuation.resume(with: result)
                }
                queue.asyncAfter(deadline: .now() + max(0.1, timeout)) { done.finish(.failure(URLError(.timedOut))) }
                let received = Buffer()
                @Sendable func read() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                        if let data { received.data.append(data) }
                        if received.data.count > maxBytes { done.finish(.failure(URLError(.dataLengthExceedsMaximum))); return }
                        if isComplete { done.finish(.success(received.data)); return }
                        if error != nil {
                            // A close after some bytes is the end of a read-to-close answer; nothing read is a failure.
                            done.finish(received.data.isEmpty ? .failure(URLError(.cannotConnectToHost)) : .success(received.data))
                            return
                        }
                        read()
                    }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { error in
                            if error != nil { done.finish(.failure(URLError(.cannotConnectToHost))) } else { read() }
                        })
                    case .failed, .waiting:
                        done.finish(.failure(URLError(.cannotConnectToHost)))
                    case .cancelled:
                        done.finish(.failure(URLError(.cancelled)))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            done.finish(.failure(URLError(.cancelled)))
        }
    }

    /// Touched only on the connection's serial queue.
    final class Buffer: @unchecked Sendable { var data = Data() }

    /// The first finish wins; later ones are dropped. A finish before `set` is kept and delivered by `set`.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((Result<Data, any Error>) -> Void)?
        private var early: Result<Data, any Error>?
        private var finished = false

        func set(_ handler: @escaping (Result<Data, any Error>) -> Void) {
            let pending: Result<Data, any Error>? = lock.withLock {
                if let early { self.early = nil; return early }
                self.handler = handler
                return nil
            }
            if let pending { handler(pending) }
        }

        func finish(_ result: Result<Data, any Error>) {
            let h: ((Result<Data, any Error>) -> Void)? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                guard let handler else { early = result; return nil }
                self.handler = nil
                return handler
            }
            h?(result)
        }
    }
}
