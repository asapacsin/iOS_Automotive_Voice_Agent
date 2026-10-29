import Foundation
import NovaKit
import NovaPorts

/// `place_call` (F-19, `A/PhoneCallTool.kt`): the first call only finds the contact and asks; only
/// `confirmed=true` for the same contact within the window dials. She never claims a call that the
/// dialler did not open (I-1); numbers are never logged (I-8).
public actor PhoneCallHandler: ToolExecutor {
    public static let tools: Set<String> = ["place_call"]
    /// How long a confirmation question stays valid. PROPOSED 30 s: the Android value
    /// (`A/PhoneCallTool.kt:48-50`) is pending an EVIDENCE_REQUEST.
    public static let confirmationWindow = NovaDuration.seconds(30)

    private struct Pending {
        let contact: Contact
        let askedAt: NovaInstant
    }

    private let contacts: any ContactsDirectory
    private let dialer: any PhoneDialer
    private let clock: any NovaClock
    private var pending: Pending?

    public init(contacts: any ContactsDirectory, dialer: any PhoneDialer, clock: any NovaClock) {
        self.contacts = contacts
        self.dialer = dialer
        self.clock = clock
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        let name = (call.arguments["contact"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return ToolDispatcher.failure(.contactNotFound) }
        guard await dialer.canPlaceCalls else {
            pending = nil
            return ToolDispatcher.failure(.noTelephony)
        }
        if call.arguments["confirmed"]?.stringValue == "true" {
            return await confirm(name)
        }
        return await lookUp(name)
    }

    private func lookUp(_ name: String) async -> ToolResult {
        pending = nil
        let found: [Contact]
        do {
            found = try await contacts.search(name).filter { !$0.phoneNumbers.isEmpty }
        } catch {
            return ToolDispatcher.failure(.contactsPermissionDenied)
        }
        switch found.count {
        case 0:
            return ToolDispatcher.failure(.contactNotFound)
        case 1:
            pending = Pending(contact: found[0], askedAt: clock.now)
            return .success([
                "status": "confirm_required",
                "contact": .string(found[0].displayName),
                "next": .string(ToolFailureAdvice.confirmCall),
            ])
        default:
            return .success([
                "status": "ambiguous",
                "candidates": .array(found.prefix(5).map { .string($0.displayName) }),
                "next": .string(ToolFailureAdvice.chooseContact),
            ])
        }
    }

    private func confirm(_ name: String) async -> ToolResult {
        guard let asked = pending, Self.sameContact(asked.contact.displayName, name) else {
            pending = nil
            return ToolDispatcher.failure(.callNotConfirmed)
        }
        pending = nil
        guard clock.now - asked.askedAt <= Self.confirmationWindow else {
            return ToolDispatcher.failure(.confirmationStale)
        }
        guard let number = asked.contact.phoneNumbers.first, await dialer.dial(number) else {
            return ToolDispatcher.failure(.callFailed)
        }
        return .success([
            "status": "dialing",
            "contact": .string(asked.contact.displayName),
            "next": .string("已经打开拨号界面，用一句话说正在给\(asked.contact.displayName)打电话。"),
        ])
    }

    /// The model may repeat the full name or the spoken one (妈妈 → 妈妈（手机）).
    static func sameContact(_ found: String, _ spoken: String) -> Bool {
        found == spoken || found.contains(spoken) || spoken.contains(found)
    }
}
