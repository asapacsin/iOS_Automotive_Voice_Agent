import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
import Synchronization

/// What the app's audio path calls on the voice model beyond `RealtimeProvider`: Gemini's manual activity marks and
/// the 100 ms audio piece. `QwenRealtimeProvider` answers them in its own terms (F-05 §15 item 3).
public protocol LiveVoiceProvider: RealtimeProvider {
    func flushAudio()
    func sendActivityStart()
    func sendActivityEnd()
    /// F-08 §15 item 1: stop her reply now (the stop phrase).
    func sendEmptyActivity()
}

extension GeminiLiveProvider: LiveVoiceProvider {}

/// F-05 §15 (T-016q): the Qwen-Audio realtime voice model behind `RealtimeProvider`. One socket at a time; the first
/// message is `session.update`; a single reader owns the assembler and a single writer keeps client messages in order.
/// A socket ends with exactly one `.failed` or `.closed`. No resumption: every connect is fresh (item 5).
public final class QwenRealtimeProvider: LiveVoiceProvider {
    /// Item 3: the capture's 10 ms frames go up as 40 ms appends.
    public static let framesPerAppend = 4
    /// The local gate sends audio only while the driver speaks; the server's turn detection needs to hear the end, so
    /// an utterance's end is followed by this much silence (PROPOSED, F-05 §15 item 3).
    public static let endSilenceFrames = 60

    /// F-05 §15 vendor facts (T-016r): `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=<model>`, fixed.
    public static func endpoint(model: String) -> URL? {
        var components = URLComponents(string: QwenRoute.realtimeEndpoint)
        components?.queryItems = [URLQueryItem(name: "model", value: model)]
        return components?.url
    }

    public let capabilities = RealtimeCapabilities(serverSpeechEvents: false, clientCancel: true, verbatimRelay: false)
    public let events: AsyncStream<ProviderEvent>

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let credentials: any RealtimeCredentialSource
    private let connector: any WebSocketConnector
    private let endpoint: @Sendable (String) -> URL?
    private let tuning: RealtimeTuning
    private let onClose: (@Sendable (SessionClosedLine) -> Void)?
    /// Item 6: `qwen usage …` and `qwen history turns=<n>` (numbers only, I-8).
    private let onLine: (@Sendable (String) -> Void)?
    private let state = Mutex<(socket: Socket?, attempt: UInt64, held: [PCMFrame16k])>((nil, 0, []))

    private final class Socket: Sendable {
        let connection: any WebSocketConnection
        let generation: Generation
        let outbox: AsyncStream<String>.Continuation
        private let pending = Mutex(0)
        private let pendingLimit: Int
        private let sink: AsyncStream<ProviderEvent>.Continuation
        private let onClose: (@Sendable (SessionClosedLine) -> Void)?
        private let ended = Mutex(false)
        private let tasks = Mutex<[Task<Void, Never>]>([])

        init(connection: any WebSocketConnection, generation: Generation, pendingLimit: Int,
             outbox: AsyncStream<String>.Continuation, sink: AsyncStream<ProviderEvent>.Continuation,
             onClose: (@Sendable (SessionClosedLine) -> Void)?) {
            self.connection = connection
            self.generation = generation
            self.pendingLimit = pendingLimit
            self.outbox = outbox
            self.sink = sink
            self.onClose = onClose
        }

        var isEnded: Bool { ended.withLock { $0 } }

        func enqueue(_ message: JSONValue) {
            guard let data = try? QwenRealtimeCodec.encode(message) else { return }
            let overflow = pending.withLock { n -> Bool in
                guard n < pendingLimit else { return true }
                n += 1
                return false
            }
            if overflow {
                end(.failed(RealtimeError(.wsFailed)))
                return
            }
            outbox.yield(String(decoding: data, as: UTF8.self))
        }

        func written() { pending.withLock { $0 -= 1 } }

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

        /// Item 4: a refused upgrade by its status; a close by its reason; a normal close is `closed`.
        func fail(_ error: Error) {
            guard let closed = error as? WebSocketClosed else {
                end(.failed(RealtimeError(.wsFailed)))
                return
            }
            let line = SessionClosedLine(code: closed.code, reason: closed.reason)
            if let status = closed.httpStatus {
                end(.failed(RealtimeError(QwenRealtimeCodec.classify(handshakeStatus: status))), closedBy: line)
            } else if closed.code == 1000 {
                end(.closed, closedBy: line)
            } else {
                end(.failed(RealtimeError(QwenRealtimeCodec.classify(closed.reason))), closedBy: line)
            }
        }

        func stop() { end(nil) }

        func own(_ started: [Task<Void, Never>]) {
            tasks.withLock { $0 += started }
            if isEnded { started.forEach { $0.cancel() } }
        }
    }

    /// `endpoint`: the socket URL for a model id (nil: no usable endpoint, a terminal credential failure).
    public init(credentials: any RealtimeCredentialSource,
                endpoint: @escaping @Sendable (String) -> URL? = { QwenRealtimeProvider.endpoint(model: $0) },
                connector: any WebSocketConnector = URLSessionWebSocketConnector(), tuning: RealtimeTuning = RealtimeTuning(),
                onClose: (@Sendable (SessionClosedLine) -> Void)? = nil, onLine: (@Sendable (String) -> Void)? = nil) {
        self.credentials = credentials
        self.endpoint = endpoint
        self.connector = connector
        self.tuning = tuning
        self.onClose = onClose
        self.onLine = onLine
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self,
                                                        bufferingPolicy: .bufferingNewest(tuning.eventBufferLimit))
    }

    /// Item 5: `handle` is ignored; Qwen has no resumption.
    public func connect(_ config: SessionConfig, resume handle: String?, connection generation: Generation) async {
        let attempt = state.withLock { s -> UInt64 in
            s.socket?.stop()
            s.socket = nil
            s.held = []
            s.attempt += 1
            return s.attempt
        }
        let request: URLRequest
        do {
            guard case .apiKey(let key) = try await credentials.credential(), !key.isEmpty,
                  let url = endpoint(config.model) else { throw RealtimeError(.credential) }
            var r = URLRequest(url: url)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request = r
        } catch {
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
        let socket = Socket(connection: connection, generation: generation, pendingLimit: tuning.outboxLimit,
                            outbox: outboxContinuation, sink: continuation, onClose: onClose)
        // Item 3: `session.update` is queued before the socket is reachable, so nothing can precede it.
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
                socket.written()
            }
        }
        let onLine = self.onLine
        let reader = Task {
            var assembler = QwenRealtimeAssembler()
            while !Task.isCancelled {
                let frame: Data
                do { frame = try await connection.receive() } catch {
                    socket.fail(error)
                    return
                }
                guard let event = QwenRealtimeCodec.decode(frame) else { continue }
                let out = assembler.consume(event)
                for e in out.events { socket.emit(e) }
                for line in out.lines { onLine?(line) }
                if let code = out.failure {
                    socket.end(.failed(RealtimeError(code)))
                    return
                }
            }
        }
        let interval = tuning.pingInterval, pongWait = tuning.pongTimeout
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(interval.milliseconds))
                if Task.isCancelled { return }
                if await !GeminiLiveProvider.ping(connection, within: pongWait) {
                    socket.fail(WebSocketClosed(code: 1006, reason: "ping"))
                    return
                }
            }
        }
        socket.own([writer, reader, pinger])
        state.withLock { s in if s.socket === socket, socket.isEnded { s.socket = nil } }
    }

    /// Item 3: `input_audio_buffer.append`, 40 ms at a time.
    public func sendAudio(_ frame: PCMFrame16k) {
        state.withLock { s in
            s.held.append(frame)
            guard s.held.count >= Self.framesPerAppend else { return }
            s.socket?.enqueue(QwenRealtimeCodec.append(s.held))
            s.held = []
        }
    }

    public func flushAudio() {
        state.withLock { s in Self.flush(&s) }
    }

    private static func flush(_ s: inout (socket: Socket?, attempt: UInt64, held: [PCMFrame16k])) {
        guard !s.held.isEmpty else { return }
        s.socket?.enqueue(QwenRealtimeCodec.append(s.held))
        s.held = []
    }

    /// The server detects turns itself (`smart_turn_v2`): no stream end and no start mark.
    public func sendAudioStreamEnd() async {}
    public func sendActivityStart() {}

    /// The utterance ended at the local gate: held audio, then silence so the server's turn detection hears the end.
    public func sendActivityEnd() {
        state.withLock { s in
            Self.flush(&s)
            let silence = Array(repeating: PCMFrame16k.silence, count: Self.framesPerAppend)
            for _ in 0..<(Self.endSilenceFrames / Self.framesPerAppend) {
                s.socket?.enqueue(QwenRealtimeCodec.append(silence))
            }
        }
    }

    /// The stop phrase: the vendor's `response.cancel` (F-08 §15 item 1 on Gemini sends an empty activity).
    public func sendEmptyActivity() { send([QwenRealtimeCodec.responseCancel]) }

    /// Item 3: one `function_call_output` per result, then one `response.create`.
    public func sendToolResponses(_ responses: [ToolResponse]) async {
        guard !responses.isEmpty else { return }
        send(responses.map(QwenRealtimeCodec.functionOutput) + [QwenRealtimeCodec.responseCreate])
    }

    /// Item 3: each turn a user message; `response.create` when the turn is complete.
    public func sendText(_ turns: [TextTurn], turnComplete: Bool) async {
        send(turns.map(QwenRealtimeCodec.message) + (turnComplete ? [QwenRealtimeCodec.responseCreate] : []))
    }

    public func close() async {
        state.withLock { s in
            s.socket?.stop()
            s.socket = nil
            s.held = []
            s.attempt += 1
        }
    }

    private func send(_ messages: [JSONValue]) {
        state.withLock { s in
            Self.flush(&s)
            for m in messages { s.socket?.enqueue(m) }
        }
    }

    private func yieldIfCurrent(_ attempt: UInt64, _ event: ProviderEvent) {
        state.withLock { s in if s.attempt == attempt { continuation.yield(event) } }
    }
}
