import NovaAgent
import NovaServices
import NovaPorts
import SwiftUI

/// F-05 §15 item 1 (T-016q): 「语音模型」 — Gemini 3.8 Live (default), Qwen Audio 3.1 Flash / Plus. A Qwen choice needs
/// the 百炼 key and the workspace API Host; without them it is disabled. The choice applies at the next connect.
struct VoiceModelSection: View {
    @AppStorage(VoiceModel.settingsKey) private var saved = VoiceModel.defaultModel.rawValue
    @AppStorage(SettingsKey.qwenTTSHost) private var qwenHost = ""
    @State private var changed = false

    private var key: String? { (try? KeychainCredentialStore().value(for: .qwenAPIKey)) ?? nil }

    var body: some View {
        Section(VoiceModel.title) {
            ForEach(VoiceModel.allCases, id: \.self) { model in
                let reason = model.disabledReason(qwenKey: key, workspaceHost: qwenHost)
                Button {
                    saved = model.rawValue
                    changed = true
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.label)
                            if let reason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if (VoiceModel(rawValue: saved) ?? VoiceModel.defaultModel) == model { Image(systemName: "checkmark") }
                    }
                }
                .disabled(reason != nil)
            }
            if changed { Text(VoiceModel.nextConnectNote).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
