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

    func readiness(_ settings: DefaultsSettingsStore, _ store: InMemoryCredentialStore) -> SettingsReadiness {
        SettingsReadiness(credentials: store, settings: settings)
    }

    @Test("Row 21: first launch deletes the key and both values and sets the flag; a second launch changes nothing")
    func firstAndSecondLaunch() {
        let store = InMemoryCredentialStore([.qwenAPIKey: "q"], retiredAccounts: ["azure_speech_key"])
        let settings = defaults()
        settings.set("azure", for: SettingsKey.voiceSource)
        settings.set("japaneast", for: "azure_region")
        settings.set("zh-CN-XiaoxiaoNeural", for: "azure_voice")
        RetiredVoiceSettings.run(credentials: store, settings: settings)
        #expect(store.retiredAccounts.isEmpty)
        #expect(settings.string("azure_region") == nil && settings.string("azure_voice") == nil)
        #expect(settings.bool("azure_removed_done") == true)
        #expect(settings.string(SettingsKey.voiceSource) == "gemini")
        #expect(store.storedKeys == [.qwenAPIKey])  // other secrets untouched

        settings.set("qwen", for: SettingsKey.voiceSource)
        settings.set("x", for: "azure_region")
        RetiredVoiceSettings.run(credentials: store, settings: settings)
        #expect(settings.string(SettingsKey.voiceSource) == "qwen" && settings.string("azure_region") == "x")
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

    @Test("Row 20: saved azure → Gemini 原声; 千问 with key and host → 千问; nothing saved → Gemini 原声; §15 move")
    func voiceChoice() {
        let host = "ws-x.ap-southeast-1.maas.aliyuncs.com"
        let store = InMemoryCredentialStore([.qwenAPIKey: "k"])

        let azure = defaults()
        azure.set("azure", for: SettingsKey.voiceSource)
        #expect(readiness(azure, store).source == .gemini)  // even before the cleanup runs
        RetiredVoiceSettings.run(credentials: store, settings: azure)
        #expect(readiness(azure, store).source == .gemini && !readiness(azure, store).revoicing)

        let qwen = defaults()
        qwen.set("qwen", for: SettingsKey.voiceSource)
        qwen.set(host, for: SettingsKey.qwenTTSHost)
        RetiredVoiceSettings.run(credentials: store, settings: qwen)
        #expect(readiness(qwen, store).source == .qwen && readiness(qwen, store).revoicing)

        let none = defaults()
        RetiredVoiceSettings.run(credentials: store, settings: none)
        #expect(readiness(none, store).source == .gemini)
        #expect(none.string(SettingsKey.voiceSource) == nil)

        let moved = defaults()
        moved.set("azure", for: SettingsKey.voiceSource)
        VoiceSourceMigration.run(moved)
        #expect(moved.string(SettingsKey.voiceSource) == "gemini")
    }
}
