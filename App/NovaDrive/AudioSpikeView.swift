import NovaAudio
import SwiftUI

/// T-001 / T-001a on the phone: runs `EchoSpike` and shows the numbers to paste into specs/open-questions.md.
/// F-08 §17 item 2: run it at 100%, 70% and 50% volume, AGC on and off; each run is added to the results.
struct AudioSpikeView: View {
    @State private var voiceProcessing = true
    @State private var agc = true
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
                    Text("依次把音量调到 100%、70%、50%，AGC 开和关各测一次，测试时保持安静。每次播放 10 段类似说话的声音，检查麦克风是否把它误当成你在说话。约 30 秒。")
                    Toggle("Apple 回声消除", isOn: $voiceProcessing)
                    Toggle("自动增益（AGC）", isOn: $agc)
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
        let vp = voiceProcessing, gain = agc
        Task {
            let line: String
            do { line = try await EchoSpike().run(voiceProcessing: vp, agc: gain).summary }
            catch { line = "失败: \(error.localizedDescription)" }
            report = [report, line].compactMap { $0 }.joined(separator: "\n\n")
            running = false
        }
    }
}
