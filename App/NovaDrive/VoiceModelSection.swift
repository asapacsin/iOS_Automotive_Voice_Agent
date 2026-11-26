import NovaAgent
import NovaVoice
import SwiftUI

/// F-05 §15 item 1 (T-016q): 「语音模型」, Gemini 3.8 Live (default) or Qwen Audio 3.1 Flash / Plus. A Qwen choice is
/// disabled without the 百炼 key; a change applies at the next connect (a running session is not switched).
struct VoiceModelSection: View {
    @AppStorage(SettingsKey.voiceModel) private var savedModel = VoiceModel.default.rawValue
    @AppStorage(SettingsKey.qwenTTSHost) private var qwenHost = ""
    let qwenKeySaved: Bool

    private var hostSaved: Bool { VoiceHostCheck.isValid(qwenHost) }

    private var selection: Binding<VoiceModel> {
        Binding(get: { VoiceModel(rawValue: savedModel) ?? .default },
                set: { model in
                    guard model.isAvailable(qwenKeySaved: qwenKeySaved, qwenHostSaved: hostSaved) else { return }
                    savedModel = model.rawValue
                })
    }

    var body: some View {
        Section("语音模型") {
            Picker("语音模型", selection: selection) {
                ForEach(VoiceModel.allCases, id: \.rawValue) { model in
                    Text(model.label).tag(model)
                        .disabled(!model.isAvailable(qwenKeySaved: qwenKeySaved, qwenHostSaved: hostSaved))
                }
            }
            if let reason = VoiceModel.qwenFlash.disabledReason(qwenKeySaved: qwenKeySaved, qwenHostSaved: hostSaved) {
                Text("Qwen：" + reason).font(.footnote).foregroundStyle(.secondary)
            }
            Text(VoiceModel.nextConnectNote).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
