import Foundation
import NovaKit
import NovaPorts
import Synchronization

/// In-memory credential store for tests and previews. Optional failure injection per key.
public final class InMemoryCredentialStore: CredentialStore {
    public struct Failure: Error, Sendable {}
    private let state = Mutex<(values: [CredentialKey: String], failing: Set<CredentialKey>)>(([:], []))
    /// F-07 §17 item 3: items under retired account names, and accounts whose removal fails.
    private let retired = Mutex<(accounts: Set<String>, failing: Set<String>)>(([], []))

    public init(_ values: [CredentialKey: String] = [:], retiredAccounts: Set<String> = []) {
        state.withLock { $0.values = values }
        retired.withLock { $0.accounts = retiredAccounts }
    }

    public func failRetiredRemoval(of account: String, _ failing: Bool = true) {
        retired.withLock { if failing { $0.failing.insert(account) } else { $0.failing.remove(account) } }
    }

    public func removeRetired(account: String) throws {
        try retired.withLock { r in
            if r.failing.contains(account) { throw Failure() }
            r.accounts.remove(account)
        }
    }

    public var retiredAccounts: Set<String> { retired.withLock { $0.accounts } }

    public func failRemoval(of key: CredentialKey) { state.withLock { _ = $0.failing.insert(key) } }

    public func value(for key: CredentialKey) throws -> String? { state.withLock { $0.values[key] } }

    public func set(_ value: String, for key: CredentialKey) throws { state.withLock { $0.values[key] = value } }

    public func remove(_ key: CredentialKey) throws {
        try state.withLock { s in
            if s.failing.contains(key) { throw Failure() }
            s.values[key] = nil
        }
    }

    public var storedKeys: Set<CredentialKey> { state.withLock { Set($0.values.keys) } }
}

/// `UserDefaults`-backed settings (non-secret only).
public final class DefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func string(_ key: String) -> String? { defaults.string(forKey: key) }
    public func bool(_ key: String) -> Bool? { defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key) }
    public func set(_ value: String?, for key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: Bool, for key: String) { defaults.set(value, forKey: key) }
}
