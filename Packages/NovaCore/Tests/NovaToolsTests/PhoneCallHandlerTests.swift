import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

struct FakeContacts: ContactsDirectory {
    var all: [Contact] = [Contact(displayName: "妈妈", phoneNumbers: ["10086"]),
                          Contact(displayName: "张伟", phoneNumbers: ["1"]),
                          Contact(displayName: "张伟（公司）", phoneNumbers: ["2"])]
    var denied = false
    func search(_ name: String) async throws -> [Contact] {
        if denied { throw ContactsError.permissionDenied }
        return all.filter { $0.displayName.contains(name) }
    }
}

final class FakeDialer: PhoneDialer {
    let telephony: Bool
    let opens: Bool
    let dialled = Mutex<[String]>([])
    init(telephony: Bool = true, opens: Bool = true) {
        self.telephony = telephony
        self.opens = opens
    }
    var canPlaceCalls: Bool { telephony }
    func dial(_ number: String) async -> Bool {
        dialled.withLock { $0.append(number) }
        return opens
    }
}

@Suite("T-070 F-19 phone call with confirmation")
struct PhoneCallHandlerTests {
    func handler(_ dialer: FakeDialer = FakeDialer(), contacts: FakeContacts = FakeContacts(),
                 clock: ManualClock = ManualClock()) -> PhoneCallHandler {
        PhoneCallHandler(contacts: contacts, dialer: dialer, clock: clock)
    }

    @Test("F-19 row 1: first call asks, nothing dialled; confirmed=true for the same contact dials")
    func confirmThenDial() async {
        let dialer = FakeDialer()
        let h = handler(dialer)
        let first = await h.execute(call("place_call", ["contact": "妈妈"]))
        #expect(first.data["status"] == "confirm_required")
        #expect(dialer.dialled.withLock { $0 }.isEmpty)
        let second = await h.execute(call("place_call", ["contact": "妈妈", "confirmed": "true"]))
        #expect(second.ok)
        #expect(second.data["status"] == "dialing")
        #expect(dialer.dialled.withLock { $0 } == ["10086"])
    }

    @Test("confirmed=true with no question asked, or for another contact, does not dial")
    func notConfirmed() async {
        let dialer = FakeDialer()
        let h = handler(dialer)
        #expect(await h.execute(call("place_call", ["contact": "妈妈", "confirmed": "true"])).code == .callNotConfirmed)
        _ = await h.execute(call("place_call", ["contact": "妈妈"]))
        #expect(await h.execute(call("place_call", ["contact": "李四", "confirmed": "true"])).code == .callNotConfirmed)
        #expect(dialer.dialled.withLock { $0 }.isEmpty)
    }

    @Test("A confirmation older than the window is stale and does not dial")
    func stale() async {
        let clock = ManualClock()
        let dialer = FakeDialer()
        let h = handler(dialer, clock: clock)
        _ = await h.execute(call("place_call", ["contact": "妈妈"]))
        clock.advance(by: PhoneCallHandler.confirmationWindow + .seconds(1))
        #expect(await h.execute(call("place_call", ["contact": "妈妈", "confirmed": "true"])).code == .confirmationStale)
        #expect(dialer.dialled.withLock { $0 }.isEmpty)
    }

    @Test("F-19 row 2 and §8: no telephony, not found, several matches, no permission, dial failed")
    func failures() async {
        #expect(await handler(FakeDialer(telephony: false)).execute(call("place_call", ["contact": "妈妈"])).code
                == .noTelephony)
        #expect(await handler().execute(call("place_call", ["contact": "李四"])).code == .contactNotFound)
        let several = await handler().execute(call("place_call", ["contact": "张伟"]))
        #expect(several.data["status"] == "ambiguous")
        #expect(several.data["candidates"] == .array(["张伟", "张伟（公司）"]))
        #expect(await handler(contacts: FakeContacts(denied: true)).execute(call("place_call", ["contact": "妈妈"])).code
                == .contactsPermissionDenied)
        let failing = handler(FakeDialer(opens: false))
        _ = await failing.execute(call("place_call", ["contact": "妈妈"]))
        #expect(await failing.execute(call("place_call", ["contact": "妈妈", "confirmed": "true"])).code == .callFailed)
    }

    @Test("Every failure carries its honest advice sentence")
    func advice() async {
        let r = await handler().execute(call("place_call", ["contact": "李四"]))
        #expect(r.advice == ToolFailureAdvice.forCode(.contactNotFound))
    }
}
