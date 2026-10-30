import Foundation
import NovaKit
import Synchronization
import Testing

@Suite("T-016g F-05 §14 ResumeOnce")
struct ResumeOnceTests {
    struct Boom: Error {}

    @Test("F-05 §14 row 1: success then error delivers the success; the second call returns false")
    func successThenError() async throws {
        var second: Bool?
        let value = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, any Error>) in
            let once = ResumeOnce(c)
            #expect(once.resume(returning: 7))
            second = once.resume(throwing: Boom())
        }
        #expect(value == 7)
        #expect(second == false)
    }

    @Test("F-05 §14 row 1: error then error throws the first once")
    func errorThenError() async {
        await #expect(throws: Boom.self) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let once = ResumeOnce(c)
                #expect(once.resume(with: Boom()))
                #expect(!once.resume(with: CancellationError()))
            }
        }
    }

    @Test("F-05 §14 row 1: many threads at once: exactly one resume wins")
    func concurrent() async {
        let wins = Mutex(0)
        _ = try? await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(c)
            DispatchQueue.concurrentPerform(iterations: 64) { i in
                let won = i.isMultiple(of: 2) ? once.resume() : once.resume(throwing: Boom())
                if won { wins.withLock { $0 += 1 } }
            }
        }
        #expect(wins.withLock { $0 } == 1)
    }
}
