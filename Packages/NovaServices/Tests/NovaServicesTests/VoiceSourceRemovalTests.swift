import Foundation
import Testing
import NovaAgent
import NovaKit
import NovaPorts
@testable import NovaServices

/// F-07 §18 row 27 (T-020e): the one-time cleanup of 「她的声音」. With VoiceSourceRemoval.swift, the only Swift file
/// allowed to name the retired keys (§18 item 6).
@Suite("T-020e F-07 §18 voice source removal")
struct VoiceSourceRemovalTests {
    @Test("T-020e F-07 row 27: first launch removes the three values and the two old flags, keeps the key, sets the flag; a second launch changes nothing")
    func row27() throws {
        let store = InMemoryCredentialStore([.qwenAPIKey: "q"])
        let settings = DefaultsSettingsStore(defaults: UserDefaults(suiteName: "t020e-\(UUID().uuidString)")!)
        settings.set("qwen", for: "voice_source")
        settings.set("ws-x.ap-southeast-1.maas.aliyuncs.com", for: "qwen_tts_host")
        settings.set("longanqian", for: "qwen_voice")
        settings.set(true, for: "voice_source_gemini_default_done")
        settings.set(true, for: RetiredVoiceSettings.doneKey)
        settings.set(VoiceModel.qwenFlash.rawValue, for: SettingsKey.voiceModel)
        VoiceSourceRemoval.run(settings: settings)
        #expect(settings.string("voice_source") == nil)
        #expect(settings.string("qwen_tts_host") == nil)
        #expect(settings.string("qwen_voice") == nil)
        #expect(settings.bool("voice_source_gemini_default_done") == nil)
        #expect(settings.bool(RetiredVoiceSettings.doneKey) == nil)
        #expect(settings.bool("voice_source_removed_done") == true)
        #expect(try store.value(for: .qwenAPIKey) == "q")
        #expect(settings.string(SettingsKey.voiceModel) == VoiceModel.qwenFlash.rawValue)  // 「语音模型」 untouched
        // Second launch: nothing changes, even values saved since.
        settings.set("later", for: "qwen_voice")
        VoiceSourceRemoval.run(settings: settings)
        #expect(settings.string("qwen_voice") == "later")
        #expect(settings.bool("voice_source_removed_done") == true)
        // The F-07 §17 cleanup does not run again after this one.
        RetiredVoiceSettings.run(credentials: store, settings: settings)
        #expect(settings.bool(RetiredVoiceSettings.doneKey) == nil)
    }
}
