import Foundation
import Testing
import NovaAgent
import NovaKit
import NovaPorts
@testable import NovaServices

/// F-07 §17 rows 20–21 (T-020d): the one-time cleanup of the removed TTS source. With RetiredVoiceSettings.swift,
/// the only Swift file allowed to name it (§17 item 6).
@Suite("T-020d F-07 §17 retired voice source cleanup")
struct RetiredVoiceSettingsTests {
    func defaults() -> DefaultsSettingsStore {
        DefaultsSettingsStore(defaults: UserDefaults(suiteName: "t020d-\(UUID().uuidString)")!)
    }

    @Test("Row 21: first launch deletes the key and both values and sets the flag; a second launch changes nothing")
    func firstAndSecondLaunch() {
        let store = InMemoryCredentialStore([.qwenAPIKey: "q"], retiredAccounts: ["azure_speech_key"])
        let settings = defaults()
        settings.set("japaneast", for: "azure_region")
        settings.set("zh-CN-XiaoxiaoNeural", for: "azure_voice")
        RetiredVoiceSettings.run(credentials: store, settings: settings)
        #expect(store.retiredAccounts.isEmpty)
        #expect(settings.string("azure_region") == nil && settings.string("azure_voice") == nil)
        #expect(settings.bool("azure_removed_done") == true)
        #expect(store.storedKeys == [.qwenAPIKey])  // other secrets untouched

        settings.set("x", for: "azure_region")
        RetiredVoiceSettings.run(credentials: store, settings: settings)
        #expect(settings.string("azure_region") == "x")
    }

    @Test("Row 21: a failed Keychain delete leaves the flag unset and is tried again on the next launch")
    func failedDeleteRetries() {
        let store = InMemoryCredentialStore(retiredAccounts: ["azure_speech_key"])
        store.failRetiredRemoval(of: "azure_speech_key")
        let settings = defaults()
        RetiredVoiceSettings.run(credentials: store, settings: settings)
        #expect(settings.bool("azure_removed_done") == nil)
        #expect(store.retiredAccounts == ["azure_speech_key"])
        store.failRetiredRemoval(of: "azure_speech_key", false)
        RetiredVoiceSettings.run(credentials: store, settings: settings)
        #expect(settings.bool("azure_removed_done") == true && store.retiredAccounts.isEmpty)
    }

    @Test("清除所有密钥 also deletes the removed TTS key")
    func wipeRemovesRetired() {
        let store = InMemoryCredentialStore([.geminiAPIKey: "g"], retiredAccounts: ["azure_speech_key"])
        #expect(CredentialWipe.wipe(store, settings: defaults()).isEmpty)
        #expect(store.retiredAccounts.isEmpty && store.storedKeys.isEmpty)
    }

    @Test("T-020e review: a failed Keychain delete is still retried after the F-07 §18 cleanup ran")
    func retryAfterVoiceSourceRemoval() {
        let store = InMemoryCredentialStore(retiredAccounts: ["azure_speech_key"])
        store.failRetiredRemoval(of: "azure_speech_key")
        let settings = defaults()
        RetiredVoiceSettings.run(credentials: store, settings: settings)
        VoiceSourceRemoval.run(settings: settings)
        store.failRetiredRemoval(of: "azure_speech_key", false)
        RetiredVoiceSettings.run(credentials: store, settings: settings)
        #expect(store.retiredAccounts.isEmpty && settings.bool("azure_removed_done") == true)
    }
}
