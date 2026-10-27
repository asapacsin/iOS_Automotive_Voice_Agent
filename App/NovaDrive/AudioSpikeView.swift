import NovaAudio
import SwiftUI

/// T-001 on the phone: runs `EchoSpike` and shows the numbers to paste into specs/open-questions.md.
struct AudioSpikeView: View {
    @State private var voiceProcessing = true
    @State private var running = false
    @State private var report: String?
    @ObservedObject private var drive = RuntimeHolder.shared.runtime.model

    var body: some View {
        NavigationStack {
            Form {
                Section("抗噪（对话进行中）") {
                    Text(drive.running ? (drive.noiseLine.isEmpty ? "等待数据…" : drive.noiseLine) : "在「驾驶」里开始对话后显示")
                        .font(.footnote.monospacedDigit())
                        .accessibilityIdentifier("noise-line")
                }
                Section {
                    Text("把音量调到最大，测试时保持安静。手机会播放 10 次类似说话的声音，检查麦克风是否把它误当成你在说话。约 30 秒。")
                    Toggle("Apple 回声消除", isOn: $voiceProcessing)
                    Button(running ? "测试中…" : "开始测试") { start() }
                        .disabled(running)
                }
                if let report {
                    Section("结果") {
                        Text(report).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        ShareLink(item: report)
                    }
                }
            }
            .navigationTitle("音频测试")
        }
    }

    private func start() {
        running = true
        report = nil
        let vp = voiceProcessing
        Task {
            do { report = try await EchoSpike().run(voiceProcessing: vp).summary }
            catch { report = "失败: \(error.localizedDescription)" }
            running = false
        }
    }
}
