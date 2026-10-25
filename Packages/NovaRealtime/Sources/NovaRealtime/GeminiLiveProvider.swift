import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
import Synchronization

/// `A/voice/GeminiLiveClient.kt` on iOS: one socket at a time, setup on open, a single reader that owns
/// the turn assembler, and a single writer that keeps client messages in order. Reconnect policy lives
/// in `VoiceSession`; a socket ends with exactly one `.failed` or `.closed` event (F-05, F-24).
public final class GeminiLiveProvider: RealtimeProvider {
    public static let endpoint = URL(string:
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!

    public let capabilities = RealtimeCapabilities(serverSpeechEvents: false, clientCancel: false, verbatimRelay: false)
    public let events: AsyncStream<RealtimeEvent>

    private let continuation: AsyncStream<RealtimeEvent>.Continuation
    private let credentials: any RealtimeCredentialSource
    private let connector: any WebSocketConnector
    private let tuning: RealtimeTuning
    private let current = Mutex<Socket?>(nil)

    /// Everything owned by one open socket; `stop()` makes its late output silent.
    private final class Socket: Sendable {
        let connection: any WebSocketConnection
        let outbox: AsyncStream<String>.Continuation
        let ended = Mutex(false)
        let tasks = Mutex<[Task<Void, Never>]>([])

        init(connection: any WebSocketConnection, outbox: AsyncStream<String>.Continuation) {
            self.connection = connection
            self.outbox = outbox
        }

        /// True for the first caller only.
        func end() -> Bool {
            ended.withLock { done in
                defer { done = true }
                return !done
            }
        }

        func stop() {
            _ = end()
            outbox.finish()
            tasks.withLock { $0.forEach { $0.cancel() } }
            connection.close()
        }
    }

    public init(credentials: any RealtimeCredentialSource, connector: any WebSocketConnector = URLSessionWebSocketConnector(),
                tuning: RealtimeTuning = RealtimeTuning()) {
        self.credentials = credentials
        self.connector = connector
        self.tuning = tuning
        (events, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self,
                                                        bufferingPolicy: .bufferingNewest(tuning.eventBufferLimit))
    }

    public func connect(_ config: SessionConfig, resume handle: String?) async {
        current.withLock { $0?.stop(); $0 = nil }
        let connection: any WebSocketConnection
        do {
            connection = try await connector.open(request(try await credentials.credential()))
        } catch is CancellationError {
            return
        } catch {
            continuation.yield(.failed(RealtimeError(.connection)))
            return
        }
        let (outbox, outboxContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let socket = Socket(connection: connection, outbox: outboxContinuation)
        current.withLock { $0 = socket }
        if let setup = try? GeminiCodec.encode(GeminiCodec.setup(config, resume: handle)) {
            outboxContinuation.yield(String(decoding: setup, as: UTF8.self))
        }
        let resumed = handle != nil
        let writer = Task { [weak self] in
            for await text in outbox {
                do { try await connection.send(text) } catch {
                    self?.end(socket, error: error, resumed: resumed)
                    return
                }
            }
        }
        let reader = Task { [weak self] in
            var assembler = GeminiTurnAssembler()
            while !Task.isCancelled {
                let frame: Data
                do { frame = try await connection.receive() } catch {
                    self?.end(socket, error: error, resumed: resumed)
                    return
                }
                guard let parts = GeminiCodec.decode(frame) else { continue }
                for event in assembler.consume(parts) where !socket.ended.withLock({ $0 }) {
                    self?.continuation.yield(event)
                }
            }
        }
        let pinger = Task { [tuning] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(tuning.pingInterval.milliseconds))
                if Task.isCancelled { return }
                try? await connection.ping()
            }
        }
        socket.tasks.withLock { $0 = [writer, reader, pinger] }
    }

    public func sendAudio(_ frame: PCMFrame16k) { send(GeminiCodec.audio([frame])) }

    public func sendAudioStreamEnd() async { send(GeminiCodec.audioStreamEnd) }

    public func sendToolResponses(_ responses: [ToolResponse]) async { send(GeminiCodec.toolResponses(responses)) }

    public func sendText(_ turns: [TextTurn], turnComplete: Bool) async {
        send(GeminiCodec.text(turns, turnComplete: turnComplete))
    }

    public func close() async {
        current.withLock { $0?.stop(); $0 = nil }
    }

    private func send(_ message: JSONValue) {
        guard let data = try? GeminiCodec.encode(message) else { return }
        current.withLock { socket in _ = socket?.outbox.yield(String(decoding: data, as: UTF8.self)) }
    }

    /// The single terminal event of a socket; nothing for one that `close()` or a new `connect` stopped.
    private func end(_ socket: Socket, error: Error, resumed: Bool) {
        guard socket.end() else { return }
        socket.stop()
        current.withLock { if $0 === socket { $0 = nil } }
        guard let closed = error as? WebSocketClosed else {
            continuation.yield(.failed(RealtimeError(.wsFailed)))
            return
        }
        if let code = GeminiCloseClassifier.classify(code: closed.code, reason: closed.reason, resumedSetup: resumed) {
            continuation.yield(.failed(RealtimeError(code)))
        } else {
            continuation.yield(.closed)
        }
    }

    private func request(_ credential: RealtimeCredential) -> URLRequest {
        switch credential {
        case .apiKey(let key):
            var request = URLRequest(url: Self.endpoint)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            return request
        case .ephemeralToken(let token):
            // PROPOSED (OQ-IOS-15): ephemeral tokens go in the query, as Google documents for Live.
            var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "access_token", value: token)]
            return URLRequest(url: components.url!)
        }
    }
}
