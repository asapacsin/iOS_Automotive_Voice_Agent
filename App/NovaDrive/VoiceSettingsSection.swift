import NovaAgent
import NovaAudio
import NovaKit
import NovaPlatform
import NovaPorts
import NovaServices
import NovaVoice
import SwiftUI

/// F-07 §14 item 2 (T-020a): 「她的声音」 — source, 千问 API Host and voice with 试听. F-07 §17: two sources only.
/// F-07 §15 item 1 (T-020b): 「Gemini 原声（最快）」 first and the default; no fields and no 试听 (her voice only
/// exists inside a session). A change applies from the next session start.
struct VoiceSettingsSection: View {
    static let previewText = "你好，我是小诺。"

    @AppStorage(SettingsKey.voiceSource) private var savedSource = ""
    @AppStorage(SettingsKey.qwenTTSHost) private var qwenHost = ""
    @AppStorage(SettingsKey.qwenVoice) private var qwenVoice = QwenVoiceOption.defaultID
    @State private var hostDraft = ""
    @State private var hostMessage: String?
    @State private var previewMessage: String?
    @State private var previewing = false
    @State private var player = PCMPreviewPlayer()
    let onChange: () -> Void

    private var source: Binding<VoiceSourceKind> {
        Binding(get: { VoiceSettingsSection.effectiveSource(savedSource) },
                set: { savedSource = $0.rawValue; onChange() })
    }

    static func effectiveSource(_ saved: String) -> VoiceSourceKind {
        VoiceSource.effectiveChoice(VoiceSourceKind(rawValue: saved))
    }

    var body: some View {
        Section("她的声音") {
            Picker("来源", selection: source) {
                Text("Gemini 原声（最快）").tag(VoiceSourceKind.gemini)
                Text("千问（阿里云）").tag(VoiceSourceKind.qwen)
            }
            switch source.wrappedValue {
            case .gemini:
                Text("她的声音就是 Gemini 实时会话的声音，不需要别的 key").font(.footnote).foregroundStyle(.secondary)
            case .qwen:
                TextField(qwenHost.isEmpty ? "API Host" : qwenHost, text: $hostDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("在百炼控制台的 API Key 页复制 API Host").font(.footnote).foregroundStyle(.secondary)
                Button("保存 API Host") { saveHost() }.disabled(hostDraft.isEmpty)
                if let hostMessage { Text(hostMessage).font(.footnote) }
                Picker("音色", selection: $qwenVoice) {
                    ForEach(QwenVoiceOption.all, id: \.id) { Text($0.label).tag($0.id) }
                }
                Button(previewing ? "试听中…" : "试听") { preview() }.disabled(previewing)
                if let previewMessage { Text(previewMessage).font(.footnote) }
            }
        }
    }

    private func saveHost() {
        let host = hostDraft
        guard VoiceHostCheck.isValid(host) else {
            hostMessage = VoiceHostCheck.invalidMessage
            return
        }
        qwenHost = host
        hostDraft = ""
        hostMessage = "已保存"
        onChange()
    }

    private func preview() {
        previewMessage = nil
        let key = (try? KeychainCredentialStore().value(for: .qwenAPIKey)) ?? nil
        if let missing = VoiceSource.qwenMissing(key: key, host: qwenHost) {
            previewMessage = missing
            return
        }
        guard let key else { return }
        previewing = true
        let client = QwenSpeechClient(config: QwenSpeechConfig(key: key, host: qwenHost, voice: qwenVoice))
        let text = Self.previewText
        Task { @MainActor in
            defer { previewing = false }
            do {
                let pcm = try await client.synthesize(text,
                                                      deadline: SpeechTuning().clauseDeadline(characters: text.count))
                try player.play(pcm)
            } catch let error as SpeechSynthesisError {
                previewMessage = "试听失败：\(error.code)"
            } catch {
                previewMessage = "试听失败：QWEN_TTS_PLAYBACK"
            }
        }
    }
}
