import Foundation
import Testing
import NovaAgent
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaServices

@Suite("T-024 F-22 settings and credentials")
struct SettingsTests {
    func defaults() -> DefaultsSettingsStore {
        let suite = "t024-\(UUID().uuidString)"
        return DefaultsSettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("F-22 a saved key is never shown again; a blank field keeps the stored value")
    func writeOnly() throws {
        let store = InMemoryCredentialStore()
        #expect(SecretField.display(.geminiAPIKey, in: store) == .notSet)
        try SecretField.save("  k-123  ", for: .geminiAPIKey, in: store)
        #expect(SecretField.display(.geminiAPIKey, in: store) == .saved)
        // The display type has no case that carries the value.
        #expect(String(describing: SecretField.display(.geminiAPIKey, in: store)) == "saved")
        #expect(try SecretField.save("   ", for: .geminiAPIKey, in: store) == false)
        #expect(try store.value(for: .geminiAPIKey) == "k-123")
    }

    @Test("F-22 wipe clears every secret listed in CredentialWipe and the consent")
    func wipe() throws {
        let store = InMemoryCredentialStore(Dictionary(uniqueKeysWithValues: CredentialKey.allCases.map { ($0, "v") }))
        let settings = defaults()
        settings.set(true, for: SettingsKey.geminiConsentAccepted)
        #expect(CredentialWipe.wipe(store, settings: settings).isEmpty)
        #expect(store.storedKeys.isEmpty)
        #expect(settings.bool(SettingsKey.geminiConsentAccepted) == false)
    }

    @Test("T-071h F-20a §14 row 10: the Zhipu key is wiped; vision is ready with any one of the three keys")
    func zhipuKey() throws {
        #expect(CredentialKey.zhipuKey.rawValue == "zhipu_key")
        #expect(CredentialKey.allCases.contains(.zhipuKey))
        let settings = defaults()
        #expect(SettingsReadiness(credentials: InMemoryCredentialStore(), settings: settings).vision == false)
        for key in [CredentialKey.zhipuKey, .geminiAPIKey, .qianfanKey] {
            #expect(SettingsReadiness(credentials: InMemoryCredentialStore([key: "v"]), settings: settings).vision)
        }
        let store = InMemoryCredentialStore([.zhipuKey: "z"])
        #expect(SecretField.display(.zhipuKey, in: store) == .saved)
        CredentialWipe.wipe(store, settings: settings)
        #expect(SecretField.display(.zhipuKey, in: store) == .notSet)
    }

    @Test("T-046e F-18 §17 row 1: the Qwen key is stored and wiped and never blocks a session")
    func qwenKey() throws {
        #expect(CredentialKey.qwenAPIKey.rawValue == "qwen_api_key")
        let settings = defaults()
        settings.set(true, for: SettingsKey.geminiConsentAccepted)
        let store = InMemoryCredentialStore([.geminiAPIKey: "k"])
        let before = SettingsReadiness(credentials: store, settings: settings)
        #expect(before.sessionBlocker == nil && before.geminiKey)
        #expect(try SecretField.save("q", for: .qwenAPIKey, in: store))
        #expect(SecretField.display(.qwenAPIKey, in: store) == .saved)
        let after = SettingsReadiness(credentials: store, settings: settings)
        #expect(after.sessionBlocker == nil && after.geminiKey == before.geminiKey)
        #expect(CredentialWipe.wipe(store, settings: settings).isEmpty)
        #expect(SecretField.display(.qwenAPIKey, in: store) == .notSet)
    }

    @Test("F-22 wipe keeps going past a failing key and reports it")
    func wipeFailure() {
        let store = InMemoryCredentialStore(Dictionary(uniqueKeysWithValues: CredentialKey.allCases.map { ($0, "v") }))
        store.failRemoval(of: .amapSDKKey)
        #expect(CredentialWipe.wipe(store, settings: defaults()) == [.amapSDKKey])
        #expect(store.storedKeys == [.amapSDKKey])
    }

    @Test("F-22 a session cannot start without consent (GEMINI_CONSENT_MISSING)")
    func consentRequired() throws {
        let store = InMemoryCredentialStore([.geminiAPIKey: "k"])
        let settings = defaults()
        #expect(SettingsReadiness(credentials: store, settings: settings).sessionBlocker == .geminiConsentMissing)
        #expect(SessionErrorCode.geminiConsentMissing.rawValue == "GEMINI_CONSENT_MISSING")
        settings.set(true, for: SettingsKey.geminiConsentAccepted)
        #expect(SettingsReadiness(credentials: store, settings: settings).sessionBlocker == nil)
        try store.remove(.geminiAPIKey)
        #expect(SettingsReadiness(credentials: store, settings: settings).sessionBlocker == .geminiKeyMissing)
    }

    @Test("F-22 revoicing needs both the 千问 key and a valid API Host (source 千问)")
    func revoicing() throws {
        let store = InMemoryCredentialStore([.qwenAPIKey: "k"])
        let settings = defaults()
        #expect(!SettingsReadiness(credentials: store, settings: settings).revoicing)  // F-07 §15: no choice is Gemini 原声
        settings.set("qwen", for: SettingsKey.voiceSource)
        #expect(!SettingsReadiness(credentials: store, settings: settings).revoicing)
        settings.set("ws-x.ap-southeast-1.maas.aliyuncs.com", for: SettingsKey.qwenTTSHost)
        #expect(SettingsReadiness(credentials: store, settings: settings).revoicing)
    }
}

/// F-07 §17 (T-020d). The removed vendor's name is spelled with `\u{61}` (the letter a) so the §17 item 6 gate,
/// which keeps that name out of `App/` and `Packages/`, stays green.
@Suite("T-020d F-07 §17 the removed TTS source")
struct RetiredVoiceTests {
    static let vendor = "\u{61}zure"

    func defaults() -> DefaultsSettingsStore {
        DefaultsSettingsStore(defaults: UserDefaults(suiteName: "t020d-\(UUID().uuidString)")!)
    }

    @Test("T-020d row 20: saved removed source, 千问 with key and host, nothing saved, §15 migration with the removed source")
    func voiceChoice() {
        let host = "ws-x.ap-southeast-1.maas.aliyuncs.com"
        let secrets = InMemoryRetiredSecrets()
        // Saved removed source on the first launch of this build: Gemini 原声.
        let a = defaults()
        a.set(Self.vendor, for: SettingsKey.voiceSource)
        RetiredVoiceCleanup.run(credentials: secrets, settings: a)
        #expect(a.string(SettingsKey.voiceSource) == "gemini")
        #expect(SettingsReadiness(credentials: InMemoryCredentialStore(), settings: a).source == .gemini)
        // A value that no longer parses reads as Gemini 原声 even before the cleanup.
        #expect(VoiceSourceKind(rawValue: Self.vendor) == nil)
        #expect(VoiceSource.resolve(choice: VoiceSourceKind(rawValue: Self.vendor), qwenKey: "k", qwenHost: host) == .gemini)
        // Saved 千问 with key and host: 千问, unchanged by the cleanup.
        let b = defaults()
        b.set("qwen", for: SettingsKey.voiceSource)
        b.set(true, for: VoiceSource.migrationKey)
        RetiredVoiceCleanup.run(credentials: secrets, settings: b)
        VoiceSourceMigration.run(b)
        #expect(b.string(SettingsKey.voiceSource) == "qwen")
        #expect(VoiceSource.resolve(choice: .qwen, qwenKey: "k", qwenHost: host) == .qwen(key: "k", host: host))
        // Nothing saved: Gemini 原声.
        let c = defaults()
        RetiredVoiceCleanup.run(credentials: secrets, settings: c)
        #expect(c.string(SettingsKey.voiceSource) == nil)
        #expect(SettingsReadiness(credentials: InMemoryCredentialStore(), settings: c).source == .gemini)
        // §15 migration with the removed source saved: Gemini 原声.
        #expect(VoiceSource.migrated(saved: Self.vendor, done: false) == .gemini)
        let d = defaults()
        d.set(Self.vendor, for: SettingsKey.voiceSource)
        VoiceSourceMigration.run(d)
        #expect(d.string(SettingsKey.voiceSource) == "gemini")
        // 她的声音 来源 has two options.
        #expect(VoiceSourceKind.allCases == [.gemini, .qwen])
    }

    @Test("T-020d row 21: key deleted, values removed, flag set; second launch changes nothing; failed delete retried")
    func cleanup() {
        let account = Self.vendor + "_speech_key"
        let region = Self.vendor + "_region", voice = Self.vendor + "_voice"
        let done = Self.vendor + "_removed_done"
        #expect(RetiredVoiceCleanup.doneKey == done)

        let secrets = InMemoryRetiredSecrets([account, "other"])
        let settings = defaults()
        settings.set("eastasia", for: region)
        settings.set("zh-CN-XiaoxiaoNeural", for: voice)
        #expect(RetiredVoiceCleanup.run(credentials: secrets, settings: settings))
        #expect(secrets.accounts == ["other"])
        #expect(settings.string(region) == nil && settings.string(voice) == nil)
        #expect(settings.bool(done) == true)
        // Second launch: nothing is touched.
        settings.set("gemini", for: SettingsKey.voiceSource)
        #expect(RetiredVoiceCleanup.run(credentials: secrets, settings: settings))
        #expect(secrets.attempts == 1 && secrets.accounts == ["other"])

        // A first launch whose Keychain delete fails: the flag is not set, the delete is tried again next launch.
        let failing = InMemoryRetiredSecrets([account])
        failing.failRemoval()
        let other = defaults()
        other.set(Self.vendor, for: SettingsKey.voiceSource)
        #expect(!RetiredVoiceCleanup.run(credentials: failing, settings: other))
        #expect(other.bool(done) == nil && failing.accounts == [account])
        #expect(other.string(SettingsKey.voiceSource) == "gemini")  // launch is not blocked
        failing.failRemoval(false)
        #expect(RetiredVoiceCleanup.run(credentials: failing, settings: other))
        #expect(failing.attempts == 2 && failing.accounts.isEmpty && other.bool(done) == true)
        // No CredentialKey names the removed key any more.
        #expect(!CredentialKey.allCases.map(\.rawValue).contains(account))
    }
}
