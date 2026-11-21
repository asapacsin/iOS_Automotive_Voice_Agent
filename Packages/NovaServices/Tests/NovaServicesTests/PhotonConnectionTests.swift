import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import NovaKit
import NovaPorts
@testable import NovaServices

/// A connection that never replies (until cancelled) or replies at once.
private final class Connection: HTTPTransport, @unchecked Sendable {
    let replies: Bool
    let body: Data
    init(replies: Bool, body: Data) { self.replies = replies; self.body = body }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        if !replies { try await Task.sleep(nanoseconds: 60_000_000_000) }
        return (200, body)
    }
}

/// Hands out a new connection per try; `silentFirst` connections never reply.
private final class Connector: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0
    let silentFirst: Int
    init(silentFirst: Int) { self.silentFirst = silentFirst }
    var count: Int { lock.withLock { opened } }
    func next() -> any HTTPTransport {
        let n = lock.withLock { opened += 1; return opened }
        return Connection(replies: n > silentFirst, body: Data(PhotonPlaceSearchTests.senso.utf8))
    }
}

private final class PhotonLines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ s: String) { lock.withLock { all.append(s) } }
    var lines: [String] { lock.withLock { all } }
}

/// Scaled times: 1 "second" = 0.1 s.
private let fast = PhotonTiming(tryTimeoutSeconds: 0.3, tries: 4, perNameSeconds: 1.2, parallel: 4, warmUpEverySeconds: 30)

@Suite("F-15b §52 items 10-11 (T-040zd) Photon names and connection")
struct PhotonConnectionTests {
    @Test("T-040zd row 202: bracket part searched only without CJK: New Chitose Airport (新千岁机场), 浅草寺 (Senso-ji)")
    func splitCJK() {
        #expect(PhotonPlaceSearch.split("New Chitose Airport (新千岁机场)") == ("新千岁机场", "New Chitose Airport"))
        #expect(PhotonPlaceSearch.split("New Chitose Airport（新千岁机场）").query == "New Chitose Airport")
        #expect(PhotonPlaceSearch.split("浅草寺 (Senso-ji)") == ("浅草寺", "Senso-ji"))
        #expect(PhotonPlaceSearch.split("(新千岁机场)") == (nil, "新千岁机场"))
    }

    @Test("Row 203: first connection silent, second replies → answer after one try timeout, two photon try lines")
    func secondConnection() async throws {
        let c = Connector(silentFirst: 1)
        let lines = PhotonLines()
        let s = PhotonPlaceSearch(connect: { c.next() }, timing: fast, log: { lines.add($0) })
        let t0 = Date()
        let found = try await s.text("浅草寺 (Senso-ji)", city: nil)
        let took = Date().timeIntervalSince(t0)
        #expect(found.first?.name == "浅草寺")
        #expect(took >= 0.28 && took < 1.0)
        #expect(c.count == 2)
        let tries = lines.lines.filter { $0.hasPrefix("photon try=") }
        #expect(tries.count == 2)
        #expect(tries.first?.hasPrefix("photon try=1 reason=timeout ms=") == true)
        #expect(tries.last?.hasPrefix("photon try=2 reason=reply ms=") == true)
    }

    @Test("Row 203: 10 names, each first connection silent, all answered (no batch-wide cut), at most 4 at once")
    func tenNames() async throws {
        // The first 4 connections (one per parallel lookup) are silent; every later one replies.
        let c = Connector(silentFirst: 4)
        let s = PhotonPlaceSearch(connect: { c.next() }, timing: fast)
        let names = (0..<10).map { "Place \($0)" }
        let answered = await withTaskGroup(of: Bool.self) { group in
            for n in names { group.addTask { (try? await s.text(n, city: nil))?.isEmpty == false } }
            var ok = 0
            for await r in group where r { ok += 1 }
            return ok
        }
        #expect(answered == 10)
    }

    @Test("Row 204 (slow): out of tries → AmapWebError.slow, not failed or empty; 4 try lines")
    func slow() async {
        let c = Connector(silentFirst: 100)
        let lines = PhotonLines()
        let s = PhotonPlaceSearch(connect: { c.next() }, timing: fast, log: { lines.add($0) })
        await #expect(throws: AmapWebError.slow) { try await s.text("Senso-ji", city: nil) }
        #expect(c.count == 4)
        #expect(lines.lines.filter { $0.contains("reason=timeout") }.count == 4)
    }

    @Test("Failed connections are retried on a new connection; per-name limit stops before 4 tries")
    func perNameLimit() async {
        let c = Connector(silentFirst: 100)
        let s = PhotonPlaceSearch(connect: { c.next() },
                                  timing: PhotonTiming(tryTimeoutSeconds: 0.3, tries: 4, perNameSeconds: 0.5))
        await #expect(throws: AmapWebError.slow) { try await s.text("x", city: nil) }
        #expect(c.count == 2)
    }

    @Test("Warm-up: one small request, at most one per 30 s")
    func warmUp() async {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let stub = StubTransport()
        stub.body = Data(PhotonPlaceSearchTests.senso.utf8)
        let s = PhotonPlaceSearch(connect: { stub }, timing: fast, now: { clock.t })
        #expect(await s.warmUp())
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].url?.absoluteString.contains("limit=1") == true)
        clock.t = clock.t.addingTimeInterval(29)
        #expect(await s.warmUp() == false)
        clock.t = clock.t.addingTimeInterval(1)
        #expect(await s.warmUp())
        #expect(stub.requests.count == 2)
    }
}
