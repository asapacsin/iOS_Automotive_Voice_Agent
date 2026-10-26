import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaRealtime

/// A scripted Gemini server: each `open` takes the next script; its frames are served in order, then
/// the socket either closes with the script's code or stays open until the client closes it.
final class FakeGeminiServer: WebSocketConnector, @unchecked Sendable {
    struct Script {
        var frames: [Data]
        var closeAfter: WebSocketClosed?
        var pingHangs = false
        /// `open` waits until `releaseOpen()`.
        var openDelay = false
    }

    private let gate = FakeInbox()

    func releaseOpen() {
        let gate = gate
        Task { await gate.push(.success(Data())) }
    }

    private let scripts: Mutex<[Script]>
    let opened = Mutex<[FakeSocket]>([])

    init(_ scripts: [Script]) { self.scripts = Mutex(scripts) }

    func open(_ request: URLRequest) async throws -> any WebSocketConnection {
        let script = scripts.withLock { $0.isEmpty ? Script(frames: [], closeAfter: nil) : $0.removeFirst() }
        let socket = FakeSocket(script: script, request: request)
        opened.withLock { $0.append(socket) }
        if script.openDelay { _ = await gate.next() }
        return socket
    }
}

/// Frames waiting for the client's `receive()`; one reader at a time.
actor FakeInbox {
    private var buffer: [Result<Data, WebSocketClosed>] = []
    private var waiter: CheckedContinuation<Result<Data, WebSocketClosed>, Never>?
    private var finished = false

    func push(_ item: Result<Data, WebSocketClosed>) {
        if let waiter { self.waiter = nil; waiter.resume(returning: item) } else { buffer.append(item) }
    }

    func finish() { push(.failure(WebSocketClosed(code: 1000, reason: ""))); finished = true }

    func next() async -> Result<Data, WebSocketClosed> {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if finished { return .failure(WebSocketClosed(code: 1000, reason: "")) }
        return await withCheckedContinuation { waiter = $0 }
    }
}

final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    let request: URLRequest
    let sent = Mutex<[String]>([])
    let closed = Mutex(false)
    private let inbox = FakeInbox()
    private let script: FakeGeminiServer.Script
    private let started = Mutex(false)

    init(script: FakeGeminiServer.Script, request: URLRequest) {
        self.script = script
        self.request = request
    }

    func send(_ text: String) async throws {
        sent.withLock { $0.append(text) }
        // Frames flow only after the client's setup, like the real server.
        guard text.contains("\"setup\""), started.withLock({ s in defer { s = true }; return !s }) else { return }
        for frame in script.frames { await inbox.push(.success(frame)) }
        if let closeAfter = script.closeAfter { await inbox.push(.failure(closeAfter)) }
    }

    func receive() async throws -> Data {
        switch await inbox.next() {
        case .success(let data): return data
        case .failure(let closed): throw closed
        }
    }

    func ping() async throws {
        // Like a black-holed URLSession ping: never calls back and ignores cancellation.
        if script.pingHangs { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
    }

    func close() {
        closed.withLock { $0 = true }
        let inbox = self.inbox
        Task { await inbox.finish() }
    }
}

struct KeyCredentials: RealtimeCredentialSource {
    func credential() async throws -> RealtimeCredential { .apiKey("test-key") }
}

struct NoKey: RealtimeCredentialSource {
    struct Missing: Error {}
    func credential() async throws -> RealtimeCredential { throw Missing() }
}

/// Wires `VoiceSession` to the provider the way the app will: connect effects open sockets, timers fire
/// at once, and every provider event goes back into the session tagged with the current connection.
final class SessionHarness {
    var session = VoiceSession()
    let provider: GeminiLiveProvider
    var states: [SessionUIState] = []
    var effects: [SessionEffect] = []
    var events: [RealtimeEvent] = []
    var stale = 0
    let config = SessionConfig(systemInstruction: "persona", tools: [])

    init(_ server: FakeGeminiServer) {
        provider = GeminiLiveProvider(credentials: KeyCredentials(), connector: server)
    }

    func apply(_ effects: [SessionEffect]) async {
        for effect in effects {
            self.effects.append(effect)
            switch effect {
            case .stateChanged(let s): states.append(s)
            case .connect(let connection, let resume): await provider.connect(config, resume: resume, connection: connection)
            case .close: await provider.close()
            case .schedule(let timer, _) where timer.kind == .reconnectDelay:
                await apply(session.handle(.timerFired(timer), at: .zero))
            default: break
            }
        }
    }

    /// Feeds provider events into the session until `done` holds for one of them.
    func run(until done: (RealtimeEvent) -> Bool) async {
        await apply(session.handle(.start, at: .zero))
        for await stamped in provider.events {
            guard stamped.connection == session.connection else {
                stale += 1
                continue
            }
            let event = stamped.event
            events.append(event)
            await apply(session.handle(.realtime(event, connection: stamped.connection), at: .zero))
            if done(event) { return }
        }
    }
}

private func frames(_ name: String) throws -> [[Data]] {
    var connections: [[Data]] = [[]]
    for entry in try Fixtures.load(name) {
        if entry.note == "reconnect with handle" { connections.append([]) }
        if let frame = entry.frame { connections[connections.count - 1].append(frame) }
    }
    return connections
}

@Suite("T-016 F-05 F-24 Gemini provider against a fake server")
struct GeminiLiveProviderTests {
    @Test("F-05 row 2 / F-24 row 1 (W4): a drop mid-turn reconnects within policy with the handle; PROCESSING, never ERROR")
    func dropMidTurn() async throws {
        let recorded = try frames("resumption")
        // Connection 1: up to the first reply audio, then the network drops (no close frame).
        func isAudio(_ frame: Data) -> Bool {
            (GeminiCodec.decode(frame) ?? []).contains { if case .modelAudio = $0 { true } else { false } }
        }
        let audioIndex = recorded[0].firstIndex(where: isAudio)
        let firstAudio = try #require(audioIndex)
        let server = FakeGeminiServer([
            .init(frames: Array(recorded[0][...firstAudio]), closeAfter: WebSocketClosed(code: 1006, reason: "")),
            .init(frames: recorded[1], closeAfter: nil),
        ])
        let harness = SessionHarness(server)
        var completed = 0
        await harness.run { event in
            if case .responseDone(_, .completed) = event { completed += 1 }
            return completed == 1
        }

        #expect(harness.events.contains(.failed(RealtimeError(.disconnect))))
        #expect(harness.states.contains(.reconnecting))
        #expect(SessionUIState.reconnecting.chip == .processing)
        #expect(!harness.states.contains(.error))
        #expect(harness.effects.contains(.diagnostic(.reconnectAttempt(attempt: 1, delay: .milliseconds(200)))))
        let sockets = server.opened.withLock { $0 }
        #expect(sockets.count == 2)
        let handles: [String] = harness.events.compactMap { if case .resumptionHandle(let h?) = $0 { h } else { nil } }
        let handle = try #require(handles.first)
        let secondSetup = try #require(sockets[1].sent.withLock { $0.first })
        #expect(secondSetup.contains("\"sessionResumption\":{\"handle\":\"\(handle)\"}"))
        #expect(harness.session.state == .listening)
        #expect(sockets[0].request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
    }

    @Test("F-05 row 3: an auth close is terminal: no retry, ERROR, and the config message")
    func authError() async throws {
        let server = FakeGeminiServer([
            .init(frames: [Data(#"{"setupComplete":{}}"#.utf8)],
                  closeAfter: WebSocketClosed(code: 1008, reason: "API key not valid. Please pass a valid API key.")),
        ])
        let harness = SessionHarness(server)
        await harness.run { if case .failed = $0 { true } else { false } }

        #expect(harness.events.last == .failed(RealtimeError(.auth)))
        #expect(harness.session.state == .error)
        #expect(harness.effects.contains(.showConfigError(.auth)))
        #expect(!harness.states.contains(.reconnecting))
        #expect(server.opened.withLock { $0.count } == 1)
    }

    @Test("F-05 client messages leave in order: setup first, then audio, stream end, tool responses, text")
    func writerOrder() async throws {
        let server = FakeGeminiServer([.init(frames: [Data(#"{"setupComplete":{}}"#.utf8)], closeAfter: nil)])
        let provider = GeminiLiveProvider(credentials: KeyCredentials(), connector: server)
        await provider.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        var it = provider.events.makeAsyncIterator()
        #expect(await it.next()?.event == .setupComplete)
        provider.sendAudio(.silence)
        provider.sendAudio(.silence)
        await provider.sendAudioStreamEnd()
        await provider.sendToolResponses([ToolResponse(id: CallID("c1")!, name: "control_climate", result: .success())])
        await provider.sendText([TextTurn(role: .user, text: "你好")], turnComplete: true)
        let socket = try #require(server.opened.withLock { $0.first })
        for _ in 0..<100 where socket.sent.withLock({ $0.count }) < 6 { try await Task.sleep(for: .milliseconds(10)) }
        let kinds = socket.sent.withLock { $0 }.map { text -> String in
            ["setup", "audioStreamEnd", "audio", "toolResponse", "clientContent"].first { text.contains("\"\($0)\"") } ?? "?"
        }
        #expect(kinds == ["setup", "audio", "audio", "audioStreamEnd", "toolResponse", "clientContent"])
        await provider.close()
    }

    @Test("F-05 a socket stopped by close() or a new connect emits nothing more")
    func closeIsSilent() async throws {
        let server = FakeGeminiServer([
            .init(frames: [Data(#"{"setupComplete":{}}"#.utf8)], closeAfter: nil),
            .init(frames: [Data(#"{"setupComplete":{}}"#.utf8)], closeAfter: WebSocketClosed(code: 1011, reason: "")),
        ])
        let provider = GeminiLiveProvider(credentials: KeyCredentials(), connector: server)
        let config = SessionConfig(systemInstruction: "p", tools: [])
        await provider.connect(config, resume: nil, connection: Generation(1))
        var it = provider.events.makeAsyncIterator()
        #expect(await it.next() == ProviderEvent(connection: Generation(1), event: .setupComplete))
        await provider.connect(config, resume: "h", connection: Generation(2))   // stops socket 1 silently
        #expect(await it.next() == ProviderEvent(connection: Generation(2), event: .setupComplete))
        #expect(await it.next() == ProviderEvent(connection: Generation(2), event: .failed(RealtimeError(.unavailable))))
        await provider.close()
    }

    @Test("F-05 row 3: no stored key is a terminal CREDENTIAL error, never a retried connection error")
    func missingKey() async throws {
        let server = FakeGeminiServer([])
        let provider = GeminiLiveProvider(credentials: NoKey(), connector: server)
        await provider.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        var it = provider.events.makeAsyncIterator()
        let event = await it.next()
        #expect(event?.event == .failed(RealtimeError(.credential)))
        #expect(!RealtimeErrorCode.credential.isRetryable)
        #expect(server.opened.withLock { $0.isEmpty })
    }

    @Test("F-24: a ping without a pong ends the socket as a retryable drop (W4 on a black-holed socket)")
    func deadPing() async throws {
        var tuning = RealtimeTuning()
        tuning.pingInterval = .milliseconds(20)
        let server = FakeGeminiServer([.init(frames: [Data(#"{"setupComplete":{}}"#.utf8)], closeAfter: nil, pingHangs: true)])
        let provider = GeminiLiveProvider(credentials: KeyCredentials(), connector: server, tuning: tuning)
        await provider.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        var it = provider.events.makeAsyncIterator()
        #expect(await it.next()?.event == .setupComplete)
        #expect(await it.next()?.event == .failed(RealtimeError(.disconnect)))
    }

    @Test("F-05: a close() while connect waits for the socket leaves nothing open and emits nothing")
    func closeDuringConnect() async throws {
        let server = FakeGeminiServer([.init(frames: [Data(#"{"setupComplete":{}}"#.utf8)], closeAfter: nil, openDelay: true)])
        let provider = GeminiLiveProvider(credentials: KeyCredentials(), connector: server)
        let connecting = Task {
            await provider.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        }
        for _ in 0..<200 where server.opened.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
        await provider.close()
        server.releaseOpen()
        await connecting.value
        let socket = try #require(server.opened.withLock { $0.first })
        #expect(socket.closed.withLock { $0 })
        #expect(socket.sent.withLock { $0.isEmpty })
    }
}

/// A socket whose writes never complete, like a stalled send buffer.
final class StalledConnector: WebSocketConnector, @unchecked Sendable {
    final class Conn: WebSocketConnection, @unchecked Sendable {
        let inbox = FakeInbox()
        func send(_ text: String) async throws {
            if text.contains("\"setup\"") {
                await inbox.push(.success(Data(#"{"setupComplete":{}}"#.utf8)))
                return
            }
            // Never completes, but ends with the writer task when the socket shuts down.
            try? await Task.sleep(for: .seconds(3600))
        }
        func receive() async throws -> Data {
            switch await inbox.next() {
            case .success(let d): return d
            case .failure(let c): throw c
            }
        }
        func ping() async throws {}
        func close() { let inbox = inbox; Task { await inbox.finish() } }
    }
    func open(_ request: URLRequest) async throws -> any WebSocketConnection { Conn() }
}

@Suite("T-016 F-05 handshake status and outbox bound")
struct GeminiProviderHandshakeTests {
    @Test("F-05: a refused upgrade 401/403 is terminal AUTH; 429 RATE_LIMITED; 5xx retryable")
    func handshakeStatus() async throws {
        #expect(GeminiCloseClassifier.classify(handshakeStatus: 401) == .auth)
        #expect(GeminiCloseClassifier.classify(handshakeStatus: 403) == .auth)
        #expect(GeminiCloseClassifier.classify(handshakeStatus: 429) == .rateLimited)
        #expect(GeminiCloseClassifier.classify(handshakeStatus: 503).isRetryable)
        #expect(GeminiCloseClassifier.classify(handshakeStatus: 404) == .connection)

        let server = FakeGeminiServer([
            .init(frames: [], closeAfter: WebSocketClosed(code: 1006, reason: "", httpStatus: 403)),
        ])
        let harness = SessionHarness(server)
        await harness.run { if case .failed = $0 { true } else { false } }
        #expect(harness.events.last == .failed(RealtimeError(.auth)))
        #expect(harness.session.state == .error)
        #expect(!harness.states.contains(.reconnecting))
        #expect(server.opened.withLock { $0.count } == 1)
    }

    @Test("F-24: a stalled writer past the outbox limit ends the socket as a retryable WS_FAILED")
    func outboxBound() async throws {
        var tuning = RealtimeTuning()
        tuning.outboxLimit = 4
        let provider = GeminiLiveProvider(credentials: KeyCredentials(), connector: StalledConnector(), tuning: tuning)
        await provider.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        var it = provider.events.makeAsyncIterator()
        #expect(await it.next()?.event == .setupComplete)
        for _ in 0..<10 { provider.sendAudio(.silence) }
        let event = await it.next()?.event
        #expect(event == .failed(RealtimeError(.wsFailed)))
        #expect(RealtimeErrorCode.wsFailed.isRetryable)
        await provider.close()
    }
}
