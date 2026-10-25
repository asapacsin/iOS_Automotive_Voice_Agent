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
    }

    private let scripts: Mutex<[Script]>
    let opened = Mutex<[FakeSocket]>([])

    init(_ scripts: [Script]) { self.scripts = Mutex(scripts) }

    func open(_ request: URLRequest) async throws -> any WebSocketConnection {
        let script = scripts.withLock { $0.isEmpty ? Script(frames: [], closeAfter: nil) : $0.removeFirst() }
        let socket = FakeSocket(script: script, request: request)
        opened.withLock { $0.append(socket) }
        return socket
    }
}

final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    let request: URLRequest
    let sent = Mutex<[String]>([])
    private let inbox: AsyncStream<Result<Data, WebSocketClosed>>
    private let feed: AsyncStream<Result<Data, WebSocketClosed>>.Continuation
    private let iterator: Mutex<AsyncStream<Result<Data, WebSocketClosed>>.Iterator?> = Mutex(nil)
    private let setupSeen: AsyncStream<Void>.Continuation
    private let setupStream: AsyncStream<Void>

    init(script: FakeGeminiServer.Script, request: URLRequest) {
        self.request = request
        (inbox, feed) = AsyncStream.makeStream()
        (setupStream, setupSeen) = AsyncStream.makeStream()
        // Frames flow only after the client's setup, like the real server.
        let frames = script.frames, closeAfter = script.closeAfter, feed = self.feed, setupStream = self.setupStream
        Task {
            for await _ in setupStream { break }
            for frame in frames { feed.yield(.success(frame)) }
            if let closeAfter { feed.yield(.failure(closeAfter)) }
        }
    }

    func send(_ text: String) async throws {
        sent.withLock { $0.append(text) }
        if text.contains("\"setup\"") { setupSeen.yield() }
    }

    func receive() async throws -> Data {
        var it = iterator.withLock { $0 } ?? inbox.makeAsyncIterator()
        let next = await it.next()
        iterator.withLock { $0 = it }
        switch next {
        case .success(let data)?: return data
        case .failure(let closed)?: throw closed
        case nil: throw WebSocketClosed(code: 1000, reason: "")
        }
    }

    func ping() async throws {}

    func close() { feed.finish() }
}

struct KeyCredentials: RealtimeCredentialSource {
    func credential() async throws -> RealtimeCredential { .apiKey("test-key") }
}

/// Wires `VoiceSession` to the provider the way the app will: connect effects open sockets, timers fire
/// at once, and every provider event goes back into the session tagged with the current connection.
final class SessionHarness {
    var session = VoiceSession()
    let provider: GeminiLiveProvider
    var states: [SessionUIState] = []
    var effects: [SessionEffect] = []
    var events: [RealtimeEvent] = []
    let config = SessionConfig(systemInstruction: "persona", tools: [])

    init(_ server: FakeGeminiServer) {
        provider = GeminiLiveProvider(credentials: KeyCredentials(), connector: server)
    }

    func apply(_ effects: [SessionEffect]) async {
        for effect in effects {
            self.effects.append(effect)
            switch effect {
            case .stateChanged(let s): states.append(s)
            case .connect(_, let resume): await provider.connect(config, resume: resume)
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
        for await event in provider.events {
            events.append(event)
            await apply(session.handle(.realtime(event, connection: session.connection), at: .zero))
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
        let firstAudio = try #require(recorded[0].firstIndex { GeminiCodec.decode($0)?.contains {
            if case .modelAudio = $0 { true } else { false } } == true })
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
        let handle = try #require(harness.events.compactMap { if case .resumptionHandle(let h?) = $0 { h } else { nil } }.first)
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
        await provider.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil)
        var it = provider.events.makeAsyncIterator()
        #expect(await it.next() == .setupComplete)
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
        await provider.connect(config, resume: nil)
        var it = provider.events.makeAsyncIterator()
        #expect(await it.next() == .setupComplete)
        await provider.connect(config, resume: "h")   // stops socket 1 silently
        #expect(await it.next() == .setupComplete)
        #expect(await it.next() == .failed(RealtimeError(.unavailable)))
        await provider.close()
    }
}
