import Foundation
import Testing
import NovaAgent
import NovaKit
import NovaPorts
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

    @Test("F-22 revoicing needs both the Azure key and a voice")
    func revoicing() throws {
        let store = InMemoryCredentialStore([.azureSpeechKey: "k"])
        let settings = defaults()
        #expect(!SettingsReadiness(credentials: store, settings: settings).revoicing)
        settings.set("zh-CN-XiaoxiaoNeural", for: SettingsKey.azureVoice)
        #expect(SettingsReadiness(credentials: store, settings: settings).revoicing)
    }
}
