#if canImport(Security)
import Foundation
import NovaKit
import NovaPorts
import Security

/// Keychain generic passwords, `kSecAttrAccessibleAfterFirstUnlock` (F-22, `AndroidKeystoreCredentialStore`).
/// Values are never logged; errors carry the OSStatus only.
public struct KeychainCredentialStore: CredentialStore {
    public struct KeychainError: Error, Sendable, Hashable { public let status: Int32 }

    private let service: String

    public init(service: String = "com.novadrive.credentials") { self.service = service }

    private func query(_ key: CredentialKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }

    public func value(for key: CredentialKey) throws -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func set(_ value: String, for key: CredentialKey) throws {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data,
                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as [String: Any]
        var status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add.merge(update) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func remove(_ key: CredentialKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
#endif
