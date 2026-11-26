import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
import Synchronization

/// The Gemini-only controls the runtime drives besides `RealtimeProvider` (manual activity, the stop's cut, the held
/// audio). F-05 §15 item 2 (T-016q): both providers offer them, so the runtime holds either one.
public protocol LiveSessionProvider: RealtimeProvider {
    func sendActivityStart()
    func sendActivityEnd()
    func flushAudio()
    func sendEmptyActivity()
}

extension GeminiLiveProvider: LiveSessionProvider {}

/// F-05 §15 items 3-5 (T-016q): Qwen-Audio realtime (百炼, Beijing) behind `RealtimeProvider`. One socket at a time;
/// the first message is `session.update`; a single writer keeps client messages in order; a single reader maps server
/// events (`QwenEventMapper`). A socket ends with exactly one `.failed` or `.closed`. No resumption, no `goAway`, no
/// tool-call cancellation, no background tools (the core handles those, item 5).
public final class QwenRealtimeProvider: LiveSessionProvider {
    public let capabilities = RealtimeCapabilities(serverSpeechEvents: false, clientCancel: false, verbatimRelay: false,
                                                   resumption: false, backgroundTools: false)
    public let events: AsyncStream<ProviderEvent>

    /// Item 3 `sendAudio`: frames go out in 40 ms messages (the capture's 10 ms frames, 4 at a time).
    public static let framesPerMessage = 4
    /// PROPOSED: the gate sends audio only while the driver speaks; this much silence after her utterance lets the
    /// server's turn detection see its end.
    public static let trailingSilenceFrames = 50

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let key: @Sendable () -> String?
    private let model: String
    private let connector: any WebSocketConnector
    private let onUsage: (@Sendable (QwenUsage) -> Void)?
    private let onClose: (@Sendable (SessionClosedLine) -> Void)?
    private let state = Mutex<(socket: Socket?, attempt: UInt64, held: [PCMFrame16k])>((nil, 0, []))

    private final class Socket: Sendable {
        let connection: any WebSocketConnection
        let generation: Generation
        let outbox: AsyncStream<String>.Continuation
        private let sink: AsyncStream<ProviderEvent>.Continuation
        private let onClose: (@Sendable (SessionClosedLine) -> Void)?
        private let ended = Mutex(false)
        private let tasks = Mutex<[Task<Void, Never>]>([])

        init(connection: any WebSocketConnection, generation: Generation, outbox: AsyncStream<String>.Continuation,
             sink: AsyncStream<ProviderEvent>.Continuation, onClose: (@Sendable (SessionClosedLine) -> Void)?) {
            self.connection = connection
            self.generation = generation
            self.outbox = outbox
            self.sink = sink
            self.onClose = onClose
        }

        var isEnded: Bool { ended.withLock { $0 } }

        func enqueue(_ message: JSONValue) {
            guard let data = try? GeminiCodec.encode(message) else { return }
            outbox.yield(String(decoding: data, as: UTF8.self))
        }

        func emit(_ event: RealtimeEvent) {
            ended.withLock { done in
                guard !done else { return }
                sink.yield(ProviderEvent(connection: generation, event: event))
            }
        }

        func end(_ event: RealtimeEvent?, closedBy line: SessionClosedLine? = nil) {
            let first = ended.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                if let line { onClose?(line) }
                if let event { sink.yield(ProviderEvent(connection: generation, event: event)) }
                return true
            }
            if first {
                outbox.finish()
                tasks.withLock { $0.forEach { $0.cancel() } }
                connection.close()
            }
        }

        /// Item 4: a socket failure as `failed` with its code; a normal close as `closed`.
        func fail(_ error: Error) {
            guard let closed = error as? WebSocketClosed else {
                end(.failed(RealtimeError(.wsFailed)))
                return
            }
            let line = SessionClosedLine(code: closed.code, reason: closed.reason)
            if closed.code == 1000, closed.httpStatus == nil {
                end(.closed, closedBy: line)
                return
            }
            end(.failed(RealtimeError(QwenRealtimeCodec.classify(code: closed.reason, status: closed.httpStatus))), closedBy: line)
        }

        func own(_ started: [Task<Void, Never>]) {
            tasks.withLock { $0 += started }
            if isEnded { started.forEach { $0.cancel() } }
        }
    }

    /// `key`: the 百炼 key (Keychain), read at each connect; `model`: item 1's id. The endpoint is fixed (T-016r).
    public init(key: @escaping @Sendable () -> String?, model: String,
                connector: any WebSocketConnector = URLSessionWebSocketConnector(), tuning: RealtimeTuning = RealtimeTuning(),
                onUsage: (@Sendable (QwenUsage) -> Void)? = nil, onClose: (@Sendable (SessionClosedLine) -> Void)? = nil) {
        self.key = key
        self.model = model
        self.connector = connector
        self.onUsage = onUsage
        self.onClose = onClose
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self,
                                                        bufferingPolicy: .bufferingNewest(tuning.eventBufferLimit))
    }

    /// Item 5: `handle` is ignored (Qwen has no resumption; the core never has one to send).
    public func connect(_ config: SessionConfig, resume handle: String?, connection generation: Generation) async {
        let attempt = state.withLock { s -> UInt64 in
            s.socket?.end(nil)
            s.socket = nil
            s.held = []
            s.attempt += 1
            return s.attempt
        }
        guard let key = key(), !key.isEmpty, let url = QwenRealtimeCodec.url(model: model) else {
            yieldIfCurrent(attempt, ProviderEvent(connection: generation, event: .failed(RealtimeError(.credential))))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let connection: any WebSocketConnection
        do {
            connection = try await connector.open(request)
        } catch {
            yieldIfCurrent(attempt, ProviderEvent(connection: generation, event: .failed(RealtimeError(.connection))))
            return
        }
        let (outbox, outboxContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let socket = Socket(connection: connection, generation: generation, outbox: outboxContinuation,
                            sink: continuation, onClose: onClose)
        // The session update is queued before the socket becomes reachable: no client message precedes it.
        socket.enqueue(QwenRealtimeCodec.sessionUpdate(config))
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
        let onUsage = self.onUsage
        let reader = Task {
            var mapper = QwenEventMapper()
            while !Task.isCancelled {
                let frame: Data
                do { frame = try await connection.receive() } catch {
                    socket.fail(error)
                    return
                }
                guard let (type, body) = QwenRealtimeCodec.decode(frame) else { continue }
                let (events, usage) = mapper.consume(type: type, body: body)
                if let usage { onUsage?(usage) }
                for event in events {
                    if case .failed = event { socket.end(event); return }
                    socket.emit(event)
                }
            }
        }
        socket.own([writer, reader])
    }

    public func sendAudio(_ frame: PCMFrame16k) {
        state.withLock { s in
            s.held.append(frame)
            guard s.held.count >= Self.framesPerMessage else { return }
            Self.flush(&s)
        }
    }

    public func flushAudio() { state.withLock { Self.flush(&$0) } }

    private static func flush(_ s: inout (socket: Socket?, attempt: UInt64, held: [PCMFrame16k])) {
        guard !s.held.isEmpty else { return }
        s.socket?.enqueue(QwenRealtimeCodec.audio(s.held))
        s.held = []
    }

    /// Server turn detection: nothing to send for the start.
    public func sendActivityStart() {}

    /// The utterance ended at the local gate: held audio, then trailing silence so the server's detection ends it.
    public func sendActivityEnd() {
        guard let silence = PCMFrame16k(samples: [Int16](repeating: 0, count: PCMFrame16k.samplesPerFrame)) else { return }
        state.withLock { s in
            Self.flush(&s)
            let frames = [PCMFrame16k](repeating: silence, count: Self.trailingSilenceFrames)
            stride(from: 0, to: frames.count, by: Self.framesPerMessage).forEach { i in
                s.socket?.enqueue(QwenRealtimeCodec.audio(Array(frames[i..<min(i + Self.framesPerMessage, frames.count)])))
            }
        }
    }

    public func sendAudioStreamEnd() async { flushAudio() }

    /// The stop phrase cuts her reply.
    public func sendEmptyActivity() { send([QwenRealtimeCodec.responseCancel]) }

    public func sendToolResponses(_ responses: [ToolResponse]) async { send(QwenRealtimeCodec.toolResponses(responses)) }

    public func sendText(_ turns: [TextTurn], turnComplete: Bool) async {
        send(QwenRealtimeCodec.text(turns, turnComplete: turnComplete))
    }

    public func close() async {
        state.withLock { s in
            s.socket?.end(nil)
            s.socket = nil
            s.held = []
            s.attempt += 1
        }
    }

    private func send(_ messages: [JSONValue]) {
        state.withLock { s in
            Self.flush(&s)
            for message in messages { s.socket?.enqueue(message) }
        }
    }

    private func yieldIfCurrent(_ attempt: UInt64, _ event: ProviderEvent) {
        state.withLock { s in if s.attempt == attempt { continuation.yield(event) } }
    }
}
