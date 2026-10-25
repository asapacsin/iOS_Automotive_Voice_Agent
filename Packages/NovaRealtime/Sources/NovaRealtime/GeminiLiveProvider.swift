import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
import Synchronization

/// `A/voice/GeminiLiveClient.kt` on iOS: one socket at a time, setup first, a single reader that owns
/// the turn assembler, and a single writer that keeps client messages in order. Reconnect policy lives
/// in `VoiceSession`; a socket ends with exactly one `.failed` or `.closed` event, and every event
/// carries the generation of the socket it came from (F-05, F-24).
public final class GeminiLiveProvider: RealtimeProvider {
    public static let endpoint = URL(string:
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!

    public let capabilities = RealtimeCapabilities(serverSpeechEvents: false, clientCancel: false, verbatimRelay: false)
    public let events: AsyncStream<ProviderEvent>

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let credentials: any RealtimeCredentialSource
    private let connector: any WebSocketConnector
    private let tuning: RealtimeTuning
    /// The live socket and the attempt counter: a `connect` or `close` that started later wins.
    private let state = Mutex<(socket: Socket?, attempt: UInt64)>((nil, 0))

    /// Everything owned by one open socket. `emit` and `end` share one lock, so no event can follow
    /// the socket's terminal event or a `stop()`.
    private final class Socket: Sendable {
        let connection: any WebSocketConnection
        let generation: Generation
        let resumed: Bool
        let outbox: AsyncStream<String>.Continuation
        private let sink: AsyncStream<ProviderEvent>.Continuation
        private let ended = Mutex(false)
        private let setupDone = Mutex(false)
        private let tasks = Mutex<[Task<Void, Never>]>([])

        init(connection: any WebSocketConnection, generation: Generation, resumed: Bool,
             outbox: AsyncStream<String>.Continuation, sink: AsyncStream<ProviderEvent>.Continuation) {
            self.connection = connection
            self.generation = generation
            self.resumed = resumed
            self.outbox = outbox
            self.sink = sink
        }

        var isEnded: Bool { ended.withLock { $0 } }

        func emit(_ event: RealtimeEvent) {
            if event == .setupComplete { setupDone.withLock { $0 = true } }
            ended.withLock { done in
                guard !done else { return }
                sink.yield(ProviderEvent(connection: generation, event: event))
            }
        }

        /// The terminal event, once; nothing after it.
        func end(_ event: RealtimeEvent?) {
            let first = ended.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                if let event { sink.yield(ProviderEvent(connection: generation, event: event)) }
                return true
            }
            if first { shutDown() }
        }

        /// Ends the socket for a transport error, classified from its close code.
        func fail(_ error: Error) {
            guard let closed = error as? WebSocketClosed else {
                end(.failed(RealtimeError(.wsFailed)))
                return
            }
            // A 1007 after setupComplete is a rejected client message, not a rejected setup or handle.
            let beforeSetup = !setupDone.withLock { $0 }
            if closed.code == 1007 && !beforeSetup {
                end(.failed(RealtimeError(.connectionClosed)))
            } else if let code = GeminiCloseClassifier.classify(code: closed.code, reason: closed.reason,
                                                                resumedSetup: resumed) {
                end(.failed(RealtimeError(code)))
            } else {
                end(.closed)
            }
        }

        /// Silent stop (`close()` or a newer `connect`).
        func stop() { end(nil) }

        func own(_ started: [Task<Void, Never>]) {
            tasks.withLock { $0 += started }
            // The socket may have ended while the tasks were starting.
            if isEnded { started.forEach { $0.cancel() } }
        }

        private func shutDown() {
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
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self,
                                                        bufferingPolicy: .bufferingNewest(tuning.eventBufferLimit))
    }

    public func connect(_ config: SessionConfig, resume handle: String?, connection generation: Generation) async {
        let attempt = state.withLock { s -> UInt64 in
            s.socket?.stop()
            s.socket = nil
            s.attempt += 1
            return s.attempt
        }
        let request: URLRequest
        do {
            request = Self.request(try await credentials.credential())
        } catch {
            // No usable key: terminal, so the session shows the settings message (F-05 row 3).
            yieldIfCurrent(attempt, ProviderEvent(connection: generation, event: .failed(RealtimeError(.credential))))
            return
        }
        let connection: any WebSocketConnection
        do {
            connection = try await connector.open(request)
        } catch {
            yieldIfCurrent(attempt, ProviderEvent(connection: generation, event: .failed(RealtimeError(.connection))))
            return
        }
        let (outbox, outboxContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let socket = Socket(connection: connection, generation: generation, resumed: handle != nil,
                            outbox: outboxContinuation, sink: continuation)
        // Setup is queued before the socket becomes reachable, so no client message can precede it.
        if let setup = try? GeminiCodec.encode(GeminiCodec.setup(config, resume: handle)) {
            outboxContinuation.yield(String(decoding: setup, as: UTF8.self))
        }
        let installed = state.withLock { s -> Bool in
            guard s.attempt == attempt else { return false }
            s.socket = socket
            return true
        }
        guard installed else {
            connection.close()
            return
        }
        let writer = Task {
            for await text in outbox {
                do { try await connection.send(text) } catch {
                    socket.fail(error)
                    return
                }
            }
        }
        let reader = Task {
            var assembler = GeminiTurnAssembler()
            while !Task.isCancelled {
                let frame: Data
                do { frame = try await connection.receive() } catch {
                    socket.fail(error)
                    return
                }
                guard let parts = GeminiCodec.decode(frame) else { continue }
                for event in assembler.consume(parts) { socket.emit(event) }
            }
        }
        let interval = tuning.pingInterval
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(interval.milliseconds))
                if Task.isCancelled { return }
                // A ping that fails or gets no pong within one interval means a dead socket (W4).
                let alive = await Self.ping(connection, within: interval)
                if !alive {
                    socket.fail(WebSocketClosed(code: 1006, reason: "ping"))
                    return
                }
            }
        }
        socket.own([writer, reader, pinger])
        state.withLock { s in if s.socket === socket, socket.isEnded { s.socket = nil } }
    }

    public func sendAudio(_ frame: PCMFrame16k) { send(GeminiCodec.audio([frame])) }

    public func sendAudioStreamEnd() async { send(GeminiCodec.audioStreamEnd) }

    public func sendToolResponses(_ responses: [ToolResponse]) async { send(GeminiCodec.toolResponses(responses)) }

    public func sendText(_ turns: [TextTurn], turnComplete: Bool) async {
        send(GeminiCodec.text(turns, turnComplete: turnComplete))
    }

    public func close() async {
        state.withLock { s in
            s.socket?.stop()
            s.socket = nil
            s.attempt += 1
        }
    }

    private func send(_ message: JSONValue) {
        guard let data = try? GeminiCodec.encode(message) else { return }
        state.withLock { s in _ = s.socket?.outbox.yield(String(decoding: data, as: UTF8.self)) }
    }

    private func yieldIfCurrent(_ attempt: UInt64, _ event: ProviderEvent) {
        state.withLock { s in if s.attempt == attempt { continuation.yield(event) } }
    }

    private static func ping(_ connection: any WebSocketConnection, within deadline: NovaDuration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await connection.ping()) != nil }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(deadline.milliseconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func request(_ credential: RealtimeCredential) -> URLRequest {
        switch credential {
        case .apiKey(let key):
            var request = URLRequest(url: endpoint)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            return request
        case .ephemeralToken(let token):
            // PROPOSED (OQ-IOS-15): ephemeral tokens go in the query. Never log errors of this request:
            // URLError userInfo carries the URL (I-7).
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "access_token", value: token)]
            return URLRequest(url: components.url!)
        }
    }
}
