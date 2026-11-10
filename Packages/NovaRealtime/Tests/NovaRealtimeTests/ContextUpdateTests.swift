import Foundation
import Testing
import NovaKit
import NovaPorts
@testable import NovaRealtime

@Suite("T-034c F-21 §16 contextUpdate on the wire")
struct ContextUpdateTests {
    @Test("F-21 §16 row 1: the update is exactly contextUpdate.systemInstruction.parts[0].text, with no tools key")
    func encoding() throws {
        let data = try GeminiCodec.encode(GeminiCodec.contextUpdate(systemInstruction: "基础\n嗲一点"))
        #expect(String(decoding: data, as: UTF8.self)
                == #"{"contextUpdate":{"systemInstruction":{"parts":[{"text":"基础\n嗲一点"}]}}}"#)
        #expect(!String(decoding: data, as: UTF8.self).contains("tools"))
    }

    @Test("F-21 §16 row 5: a setup with a handle is followed by the update before any audio; none without a handle")
    func resumedSetupThenUpdate() async throws {
        let server = FakeGeminiServer([.init(frames: [Data(#"{"setupComplete":{}}"#.utf8)], closeAfter: nil),
                                       .init(frames: [Data(#"{"setupComplete":{}}"#.utf8)], closeAfter: nil)])
        let provider = GeminiLiveProvider(credentials: KeyCredentials(), connector: server)
        var config = SessionConfig(systemInstruction: "original", tools: [])
        config.resumeInstructionUpdate = "current"
        await provider.connect(config, resume: "h1", connection: Generation(1))
        provider.sendAudio(.silence)
        provider.flushAudio()
        let socket = try #require(server.opened.withLock { $0.first })
        for _ in 0..<100 where socket.sent.withLock({ $0.count }) < 3 { try await Task.sleep(for: .milliseconds(10)) }
        let kinds = socket.sent.withLock { $0 }.map { text -> String in
            ["setup", "contextUpdate", "audio"].first { text.contains("\"\($0)\"") } ?? "?"
        }
        #expect(kinds == ["setup", "contextUpdate", "audio"])
        #expect(socket.sent.withLock { $0 }[0].contains("original"))
        #expect(socket.sent.withLock { $0 }[1].contains("current"))

        // Without a handle the setup already holds the instruction it was given: no update.
        await provider.connect(config, resume: nil, connection: Generation(2))
        let second = try #require(server.opened.withLock { $0.count == 2 ? $0[1] : nil })
        for _ in 0..<100 where second.sent.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!second.sent.withLock { $0 }.contains { $0.contains("contextUpdate") })
        await provider.close()
    }

    @Test("F-21 §16 item 1: sendContextUpdate goes on the open connection in order with the other messages")
    func sendOnOpenConnection() async throws {
        let server = FakeGeminiServer([.init(frames: [Data(#"{"setupComplete":{}}"#.utf8)], closeAfter: nil)])
        let provider = GeminiLiveProvider(credentials: KeyCredentials(), connector: server)
        await provider.connect(SessionConfig(systemInstruction: "p", tools: []), resume: nil, connection: Generation(1))
        var it = provider.events.makeAsyncIterator()
        #expect(await it.next()?.event == .setupComplete)
        await provider.sendContextUpdate(systemInstruction: "new")
        await provider.sendText([TextTurn(role: .user, text: "你好")], turnComplete: true)
        let socket = try #require(server.opened.withLock { $0.first })
        for _ in 0..<100 where socket.sent.withLock({ $0.count }) < 3 { try await Task.sleep(for: .milliseconds(10)) }
        let kinds = socket.sent.withLock { $0 }.map { text -> String in
            ["setup", "contextUpdate", "clientContent"].first { text.contains("\"\($0)\"") } ?? "?"
        }
        #expect(kinds == ["setup", "contextUpdate", "clientContent"])
        await provider.close()
    }
}
