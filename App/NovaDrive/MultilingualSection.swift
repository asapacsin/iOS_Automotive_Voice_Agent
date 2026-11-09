import NovaVoice
import SwiftUI

/// F-05a §14 item 1 (T-016l): 设置 → 「语音识别」: the multilingual switch, the model state and its buttons.
struct MultilingualSection: View {
    @AppStorage(MultilingualModelStore.switchKey) private var on = true
    @State private var state = MultilingualModelStore.shared.state
    @State private var confirmDelete = false
    private let store = MultilingualModelStore.shared

    var body: some View {
        Section("语音识别") {
            Toggle("多语言识别（中文 / English / 日本語）", isOn: $on)
                .onChange(of: on) { _, now in now ? store.start() : store.switchOff() }
            if state == .failed {
                Button(state.label) { store.retry() }
            } else {
                Text(state.label).foregroundStyle(.secondary)
            }
            if on, store.offersCellular {
                Button("用流量下载") { store.useCellular() }
            }
            if state == .ready || state == .loadFailed {
                Button("删除多语言模型", role: .destructive) { confirmDelete = true }
                    .confirmationDialog("删除多语言模型？", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("删除", role: .destructive) { store.delete() }
                    }
            }
            Text("开：说完一句话后，用下载到手机上的模型识别中文、英文或日语，她用你说的语言回答。只在 Wi-Fi 下自动下载；声音只在手机上处理。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: .multilingualModelState)) { _ in state = store.state }
    }
}
