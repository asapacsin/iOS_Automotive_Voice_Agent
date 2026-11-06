import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaRealtime

@Suite("T-016k F-24 §16 provider close log and dead-socket check")
struct ProviderCloseTests {
    static let setup = Data(#"{"setupComplete":{}}"#.utf8)

    /// Opens one socket on `script`, collects its events up to the terminal one, and its `providerClosed` lines.
    static func run(_ script: FakeGeminiServer.Script, tuning: RealtimeTuning = RealtimeTuning(),
                    resume: String? = nil) async -> (events: [RealtimeEvent], lines: [String], ms: Int64) {
        let lines = Mutex<[String]>([])
        let provider = GeminiLiveProvider(credentials: KeyCredentials(), connector: FakeGeminiServer([script]),
                                          tuning: tuning, onClose: { close in lines.withLock { $0.append(close.logLine) } })
        let start = ContinuousClock.now
        await provider.connect(SessionConfig(systemInstruction: "p", tools: []), resume: resume, connection: Generation(1))
        var events: [RealtimeEvent] = []
        for await event in provider.events {
            events.append(event.event)
            if case .failed = event.event { break }
            if event.event == .closed { break }
        }
        let elapsed = ContinuousClock.now - start
        // The line is written right after the terminal event.
        for _ in 0..<100 where lines.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(5)) }
        return (events, lines.withLock { $0 }, elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    @Test("F-24 §16 row 4: a 1011 close frame and a socket with no close frame are logged with code, reason and kind")
    func row4CloseLines() async throws {
        let server = await Self.run(.init(frames: [Self.setup],
                                          closeAfter: WebSocketClosed(code: 1011, reason: "x", responseStatus: 101)),
                                    resume: "h1")
        #expect(server.events.last == .failed(RealtimeError(.unavailable, unreachable: false)))
        let serverLine = try #require(server.lines.first)
        #expect(server.lines.count == 1)
        #expect(serverLine.hasPrefix("providerClosed code=1011 reason=x http=101 afterSetup=yes resumed=yes openMs="))
        #expect(serverLine.hasSuffix(" kind=server"))

        let dropped = await Self.run(.init(frames: [], closeAfter: WebSocketClosed(code: 1006, reason: "")))
        #expect(dropped.events.last == .failed(RealtimeError(.disconnect, unreachable: true)))
        let droppedLine = try #require(dropped.lines.first)
        #expect(droppedLine.hasPrefix("providerClosed code=1006 reason= http=none afterSetup=no resumed=no openMs="))
        #expect(droppedLine.hasSuffix(" kind=unreachable"))

        for line in [serverLine, droppedLine] {
            #expect(!line.contains("test-key") && !line.contains("wss://") && !line.contains("googleapis")
                    && !line.contains("access_token"))
        }
    }

    @Test("F-24 §16 row 4: the reason is cut to 120 characters, one line")
    func row4ReasonLimit() {
        let close = ProviderClose(code: 1008, reason: String(repeating: "a", count: 200) + "\nb", http: 101,
                                  afterSetup: false, resumed: false, openMs: 12, unreachable: false)
        #expect(close.reason.count == 120 && !close.logLine.contains("\n"))
    }

    @Test("F-24 §16 row 5: no pong for the pong timeout closes the socket as unreachable within interval + timeout")
    func row5DeadSocket() async throws {
        var tuning = RealtimeTuning()
        // Scaled down 100x from 10 s / 5 s: the bound is interval + pong timeout after the last pong (here, the open).
        tuning.pingInterval = .milliseconds(100)
        tuning.pongTimeout = .milliseconds(50)
        let run = await Self.run(.init(frames: [Self.setup], closeAfter: nil, pingHangs: true), tuning: tuning)
        #expect(run.events == [.setupComplete, .failed(RealtimeError(.disconnect, unreachable: true))])
        #expect(run.ms >= 150 && run.ms < 600)
        let line = try #require(run.lines.first)
        #expect(line.hasPrefix("providerClosed code=1006 reason= ") && line.hasSuffix(" kind=unreachable"))
    }
}
