import Foundation
import NovaKit
import NovaPorts
import Synchronization

/// In-memory credential store for tests and previews. Optional failure injection per key.
public final class InMemoryCredentialStore: CredentialStore {
    public struct Failure: Error, Sendable {}
    private let state = Mutex<(values: [CredentialKey: String], failing: Set<CredentialKey>)>(([:], []))

    public init(_ values: [CredentialKey: String] = [:]) {
        state.withLock { $0.values = values }
    }

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

/// In-memory items of removed features (F-07 §17 item 3), for tests. Optional failure injection.
public final class InMemoryRetiredSecrets: RetiredSecretRemover {
    public struct Failure: Error, Sendable {}
    private let state = Mutex<(accounts: Set<String>, failing: Bool, attempts: Int)>(([], false, 0))

    public init(_ accounts: Set<String> = []) { state.withLock { $0.accounts = accounts } }

    public func failRemoval(_ failing: Bool = true) { state.withLock { $0.failing = failing } }

    public func removeRetired(account: String) throws {
        try state.withLock { s in
            s.attempts += 1
            if s.failing { throw Failure() }
            s.accounts.remove(account)
        }
    }

    public var accounts: Set<String> { state.withLock { $0.accounts } }
    public var attempts: Int { state.withLock { $0.attempts } }
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
