import NovaPorts
import NovaRealtime
import NovaServices
import SwiftUI

/// T-003: records the Gemini Live contract fixtures on the phone (Documents/fixtures, shared over USB).
struct RecorderView: View {
    private let scenarios = ["plain", "tool", "interrupted", "resumption", "close1008", "close1007", "goaway"]
    @State private var running = false
    @State private var lines: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("用已保存的 Gemini key 录制 7 段测试数据。全部是脚本文字，不用说话。goAway 最长等 16 分钟。")
                    Button(running ? "录制中…" : "录制全部") { start(scenarios) }.disabled(running)
                    Button("只录前 6 段") { start(Array(scenarios.dropLast())) }.disabled(running)
                    Button("只录 goAway") { start(["goaway"]) }.disabled(running)
                }
                Section("日志") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
                }
            }
            .navigationTitle("录制")
        }
    }

    private func start(_ names: [String]) {
        running = true
        lines = []
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            do {
                guard let key = try KeychainCredentialStore().value(for: .geminiAPIKey), !key.isEmpty else {
                    throw GeminiRecorder.Failure(description: "没有 Gemini key，请先在设置里保存")
                }
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("fixtures")
                let recorder = try GeminiRecorder(key: key, directory: dir) { line in
                    Task { @MainActor in lines.append(line) }
                }
                for name in names {
                    do { try await recorder.record(name) } catch { lines.append("✗ \(name): \(error)") }
                }
                lines.append("完成")
            } catch {
                lines.append("✗ \(error)")
            }
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
