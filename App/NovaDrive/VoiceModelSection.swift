import NovaAgent
import SwiftUI

/// F-05 §15 item 1 (T-016q): 「语音模型」, Gemini 3.8 Live (default) or Qwen Audio 3.1 Flash / Plus. A Qwen choice is
/// disabled without the 百炼 key (T-016r: no API Host needed); a change applies at the next connect (a running session is not switched).
struct VoiceModelSection: View {
    @AppStorage(SettingsKey.voiceModel) private var savedModel = VoiceModel.default.rawValue
    let qwenKeySaved: Bool

    private var selection: Binding<VoiceModel> {
        Binding(get: { VoiceModel(rawValue: savedModel) ?? .default },
                set: { model in
                    guard model.isAvailable(qwenKeySaved: qwenKeySaved) else { return }
                    savedModel = model.rawValue
                })
    }

    var body: some View {
        Section("语音模型") {
            Picker("语音模型", selection: selection) {
                ForEach(VoiceModel.allCases, id: \.rawValue) { model in
                    Text(model.label).tag(model)
                        .disabled(!model.isAvailable(qwenKeySaved: qwenKeySaved))
                }
            }
            if let reason = VoiceModel.qwenFlash.disabledReason(qwenKeySaved: qwenKeySaved) {
                Text("Qwen：" + reason).font(.footnote).foregroundStyle(.secondary)
            }
            Text(VoiceModel.nextConnectNote).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
