import NovaAgent
import NovaKit
import NovaPorts
import NovaRealtime
import NovaServices
import NovaTools
import os
import Synchronization
import SwiftUI

/// Silent music for the test: plays nothing, only reports playing, so music outcomes can be scored.
final class EvalMusic: MusicPort {
    private let playing = Mutex(false)
    func set(_ on: Bool) { playing.withLock { $0 = on } }
    func playBundled() async -> Bool {
        playing.withLock { $0 = true }
        return true
    }
    func stop() async { playing.withLock { $0 = false } }
    var isPlaying: Bool { get async { playing.withLock { $0 } } }
}

/// The simulated speed of the case being run (km/h, nil = unknown).
final class EvalSpeed: Sendable {
    private let value = Mutex<Double?>(nil)
    func set(_ v: Double?) { value.withLock { $0 = v } }
    func get() -> Double? { value.withLock { $0 } }
}

/// Runs the test off the view; the view only reads what it publishes.
@MainActor
final class ComfortEvalModel: ObservableObject {
    @Published var running = false
    @Published var done = 0
    @Published var total = 0
    @Published var report: ComfortReport?
    @Published var reportMode = ToolCatalog.ComfortMode.table
    private var runner: ComfortEvalRunner?

    func cancel() {
        guard let runner else { return }
        Task { await runner.cancel() }
    }

    func start(_ mode: ToolCatalog.ComfortMode) {
        guard !running else { return }
        let vehicle = SimulatedVehicle()
        let music = EvalMusic()
        let speed = EvalSpeed()
        let speedKmh: @Sendable () async -> Double? = { speed.get() }
        let port = PolicedVehiclePort(vehicle, speedKmh: speedKmh)
        var tools: [String: any ToolExecutor] = [:]
        let vehicleTools = VehicleToolExecutor(port: port)
        for name in VehicleToolExecutor.tools { tools[name] = vehicleTools }
        let musicTools = MusicToolHandler(music: music, clock: SystemClock())
        for name in MusicToolHandler.tools { tools[name] = musicTools }
        switch mode {
        case .table: tools[ScenarioToolHandler.tool] = ScenarioToolHandler(port: port, music: music)
        case .model:
            tools[VehicleStateTool.tool] = VehicleStateTool(port: port, music: music, navigating: { false }, speedKmh: speedKmh)
        }
        let harness = ComfortEvalHarness(
            reset: { state in
                vehicle.reset(climate: state.climate, cabin: state.cabin)
                vehicle.failWindows(state.windowsFail)
                music.set(state.musicPlaying)
                speed.set(state.speedKmh)
            },
            snapshot: {
                ComfortVehicleState(climate: await vehicle.climateState(), cabin: await vehicle.cabinState(),
                                    musicPlaying: await music.isPlaying, speedKmh: speed.get())
            },
            tools: tools)
        let instruction = PersonaInstruction.build(base: PersonaInstruction.base(for: mode),
                                                   style: SpeakingStyle.saved(in: DefaultsSettingsStore()))
        let config = SessionConfig(systemInstruction: instruction, tools: ToolCatalog.declarations(for: mode), thinkingLevel: nil)
        let runner = ComfortEvalRunner(provider: GeminiLiveProvider(credentials: KeychainRealtimeCredentials()), config: config,
                                       harness: harness, clock: SystemClock())
        self.runner = runner
        running = true
        done = 0
        total = ComfortCases.all.count * ComfortEvalRunner.attempts
        Task { [weak self] in
            let runs = await runner.runAll(ComfortCases.all) { done, _ in
                await MainActor.run { self?.done = done }
            }
            let result = ComfortReport(cases: ComfortCases.all, runs: runs)
            // I-8: numbers and case ids only.
            RuntimeLog.agent.notice("\(result.logLine(mode: mode), privacy: .public)")
            self?.report = result
            self?.reportMode = mode
            self?.running = false
            self?.runner = nil
        }
    }
}

/// F-12 §14 items 4-5 (T-031a): 设置 → 舒适场景测试. Sends every case as text through a real Gemini session with the
/// app's tools and checks, on a simulated vehicle reset per case, 3 runs each. Run it with the table first (baseline),
/// then in model mode; screenshot both reports. Keys come from the Keychain and never appear in the report.
struct ComfortEvalView: View {
    @State private var mode = ToolCatalog.ComfortMode.table
    @StateObject private var eval = ComfortEvalModel()

    var body: some View {
        Form {
            Section {
                Picker("测试哪种", selection: $mode) {
                    Text("固定场景表").tag(ToolCatalog.ComfortMode.table)
                    Text("模型决定").tag(ToolCatalog.ComfortMode.model)
                }
                .pickerStyle(.segmented)
                .disabled(eval.running)
                Text("\(ComfortCases.all.count) 条句子，每条 3 次，用文字发给 Gemini，车辆是模拟的，每条都从头开始。先测固定场景表，再测模型决定，两次都截图。大约 15 分钟，会用 Gemini 额度。")
                    .font(.footnote).foregroundStyle(.secondary)
                if eval.running {
                    ProgressView(value: Double(eval.done), total: Double(max(eval.total, 1)))
                    Text("\(eval.done) / \(eval.total)").font(.footnote.monospacedDigit())
                    Button("停止", role: .destructive) { eval.cancel() }
                } else {
                    Button("开始测试") { eval.start(mode) }
                }
            }
            if let report = eval.report { reportSections(report) }
        }
        .navigationTitle("舒适场景测试")
    }

    @ViewBuilder
    private func reportSections(_ r: ComfortReport) -> some View {
        Section("结果（\(eval.reportMode == .table ? "固定场景表" : "模型决定")）") {
            row("总分", r.overall)
            row("调参集", r.tuning)
            row("保留集", r.heldOut)
            row("没写进提示的说法", r.unprompted)
            row("不该做的没有做", r.noWrongfulAction)
            ForEach(ComfortDecision.allCases, id: \.self) { d in row("期望 \(d.rawValue)", r.byDecision[d] ?? ComfortReport.Tally()) }
            LabeledContent("到第一声（中位 / 最慢）",
                           value: "\(r.medianFirstAudioMs.map { "\($0) ms" } ?? "—") / \(r.worstFirstAudioMs.map { "\($0) ms" } ?? "—")")
            LabeledContent("每次工具调用", value: String(format: "%.2f", r.callsPerRun))
            LabeledContent("被规则拦下", value: "\(r.blocked)")
            LabeledContent("没有依据的说法", value: "\(r.unbackedClaims)")
        }
        Section("失败（\(r.failures.count)）") {
            ForEach(Array(r.failures.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(f.caseID) #\(f.attempt) · \(f.reason.code)").font(.footnote.monospaced())
                    if let c = ComfortCases.all.first(where: { $0.id == f.caseID }) {
                        Text("「\(c.sentence)」").font(.footnote)
                    }
                    Text(f.reply.isEmpty ? "（没有回复）" : f.reply).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ title: String, _ t: ComfortReport.Tally) -> some View {
        LabeledContent(title, value: "\(t.passed)/\(t.total)  \(t.percent)%")
    }
}
