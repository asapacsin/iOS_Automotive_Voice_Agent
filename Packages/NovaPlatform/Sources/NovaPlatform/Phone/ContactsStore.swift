@preconcurrency import Contacts
import Foundation
import NovaPorts

/// F-19 contacts lookup (`CNContactStore`): names matching the spoken one, with their phone numbers.
/// Asks for access on first use; numbers are never logged (I-8).
public struct ContactsStore: ContactsDirectory {
    public init() {}

    public func search(_ name: String) async throws -> [Contact] {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: break
        case .notDetermined:
            guard (try? await store.requestAccess(for: .contacts)) == true else { throw ContactsError.permissionDenied }
        default:
            throw ContactsError.permissionDenied
        }
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                    CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor]
        let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
        return found.compactMap { contact in
            let display = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.nickname
            guard !display.isEmpty else { return nil }
            return Contact(displayName: display, phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue })
        }
    }
}
