import NovaAgent
import NovaKit
import NovaPorts
import NovaRealtime
import NovaServices
import Foundation
import NovaTools
import os
import Synchronization
import SwiftUI
import UIKit

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
    /// §16 item 3: the last run was 「试跑」; every reply is shown.
    @Published var reportIsTrial = false
    @Published var trialRuns: [ComfortRun] = []
    /// §16 item 7: the latest full report per mode, from a local file (never logged).
    @Published var saved: [ToolCatalog.ComfortMode: ComfortSummary] = ComfortSummaryStore.load()
    private var runner: ComfortEvalRunner?

    /// §16 item 9: the app left the foreground; the run in progress is repeated and not scored.
    func backgrounded() {
        guard let runner else { return }
        Task { await runner.setActive(false) }
    }

    func foregrounded() {
        guard let runner else { return }
        Task { await runner.setActive(true) }
    }

    func cancel() {
        guard let runner else { return }
        Task { await runner.cancel() }
    }

    func start(_ mode: ToolCatalog.ComfortMode, trial: Bool) {
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
        let cases = trial ? ComfortCases.trial : ComfortCases.all
        let attempts = trial ? 1 : ComfortEvalRunner.attempts
        total = cases.count * attempts
        // §16 item 9: the screen stays on during a run.
        UIApplication.shared.isIdleTimerDisabled = true
        Task { [weak self] in
            let runs = await runner.runAll(cases, attempts: attempts) { done, _ in
                await MainActor.run { self?.done = done }
            }
            let result = ComfortReport(cases: ComfortCases.all, runs: runs, attempts: attempts)
            let complete = !(await runner.wasCancelled)
                && runs.filter { $0.problem != .interrupted }.count == cases.count * attempts
            // I-8: numbers, enums and case ids only; one line each so nothing is cut off.
            for line in result.logLines(mode: mode) { RuntimeLog.agent.notice("\(line, privacy: .public)") }
            // §15 item 4: each block as in a drive (tool and rule only).
            for b in result.blocks {
                RuntimeLog.agent.notice("vehicleBlocked \(b.tool, privacy: .public) \(b.rule, privacy: .public) case=\(b.caseID, privacy: .public)")
            }
            UIApplication.shared.isIdleTimerDisabled = false
            if !trial, complete, result.valid {
                let summary = ComfortSummary(report: result, mode: mode, build: ComfortSummaryStore.build,
                                             date: Date().formatted(.iso8601.year().month().day()))
                ComfortSummaryStore.save(summary)
                self?.saved[mode] = summary
            }
            self?.report = result
            self?.reportMode = mode
            self?.reportIsTrial = trial
            self?.trialRuns = trial ? runs.filter { $0.problem != .interrupted } : []
            self?.running = false
            self?.runner = nil
        }
    }
}

/// §16 item 7: the latest full report per mode, kept in Application Support (not the log, not the cloud).
enum ComfortSummaryStore {
    static var build: String {
        let info = Bundle.main.infoDictionary
        // F-13a §10 item 1 (T-032i): the build's commit tells code changes apart (every build reads 0.1.0(1)).
        let raw = info?[BuildStamp.infoKey] as? String
        let stamp = BuildStamp.appVersion(short: info?["CFBundleShortVersionString"] as? String,
                                          build: info?["CFBundleVersion"] as? String, commit: raw)
        guard BuildStamp.commit(raw) == "unknown" else { return stamp }
        // No commit (a local build): the binary's build time still tells code changes apart, as before.
        let built = (Bundle.main.executablePath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] }
                     as? Date).map { Int($0.timeIntervalSince1970) } ?? 0
        return "\(stamp)-\(built)"
    }

    private static func url(_ mode: ToolCatalog.ComfortMode) -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("comfortEval-\(mode.rawValue).json")
    }

    static func load() -> [ToolCatalog.ComfortMode: ComfortSummary] {
        var out: [ToolCatalog.ComfortMode: ComfortSummary] = [:]
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            if let url = url(mode), let data = try? Data(contentsOf: url),
               let s = try? JSONDecoder().decode(ComfortSummary.self, from: data) { out[mode] = s }
        }
        return out
    }

    static func save(_ s: ComfortSummary) {
        guard let mode = ToolCatalog.ComfortMode(rawValue: s.mode), let url = url(mode),
              let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// F-12 §14 items 4-5 (T-031a): 设置 → 舒适场景测试. Sends every case as text through a real Gemini session with the
/// app's tools and checks, on a simulated vehicle reset per case, 3 runs each. Run it with the table first (baseline),
/// then in model mode; screenshot both reports. Keys come from the Keychain and never appear in the report.
struct ComfortEvalView: View {
    @State private var mode = ToolCatalog.ComfortMode.table
    @StateObject private var eval = ComfortEvalModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Picker("测试哪种", selection: $mode) {
                    Text("固定场景表").tag(ToolCatalog.ComfortMode.table)
                    Text("模型决定").tag(ToolCatalog.ComfortMode.model)
                }
                .pickerStyle(.segmented)
                .disabled(eval.running)
                Text("先「试跑」\(ComfortCases.trial.count) 条（约 2 分钟），读完每条回复再做完整测试：\(ComfortCases.all.count) 条句子，每条 3 次，用文字发给 Gemini，车辆是模拟的，每条都从头开始。同一天、同一个网络，先测固定场景表，再测模型决定，两次都截图。每种大约 30 分钟，会用 Gemini 额度。测试时屏幕常亮，不要切出应用。")
                    .font(.footnote).foregroundStyle(.secondary)
                if eval.running {
                    ProgressView(value: Double(eval.done), total: Double(max(eval.total, 1)))
                    Text("\(eval.done) / \(eval.total)").font(.footnote.monospacedDigit())
                    Button("停止", role: .destructive) { eval.cancel() }
                } else {
                    Button("试跑") { eval.start(mode, trial: true) }
                    Button("完整测试") { eval.start(mode, trial: false) }
                }
            }
            if let report = eval.report { reportSections(report) }
            comparisonSection
            Section("待定答案（\(ComfortCases.awaitingVerdict.count)）") {
                Text(ComfortCases.awaitingVerdict.joined(separator: "、")).font(.footnote.monospaced())
                if !ComfortCases.disputed.isEmpty {
                    Text("有争议，不计分：" + ComfortCases.disputed.sorted().joined(separator: "、")).font(.footnote)
                }
            }
        }
        .navigationTitle("舒适场景测试")
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { eval.foregrounded() } else { eval.backgrounded() }
        }
    }

    @ViewBuilder
    private func reportSections(_ r: ComfortReport) -> some View {
        Section("结果（\(eval.reportMode == .table ? "固定场景表" : "模型决定")\(eval.reportIsTrial ? " · 试跑" : "")）") {
            LabeledContent("有效", value: r.valid ? "是" : "否（连接失败超过 5%）")
            LabeledContent("连接失败（不计分）", value: "\(r.infrastructure.count) / \(r.runs)")
            row("总分", r.overall)
            row("调参集", r.tuning)
            row("保留集", r.heldOut)
            row("新保留集", r.freshHeldOut)
            row("最新保留集（决定用）", r.newHeldOut)
            row("3 次都过", r.allRunsPass)
            ForEach(ComfortDecision.allCases, id: \.self) { d in
                row("3 次都过 · \(d.rawValue)", r.allRunsPassByDecision[d] ?? ComfortReport.Tally())
            }
            LabeledContent("中途切出（重跑，不计分）", value: "\(r.interrupted)")
            row("没写进提示的说法", r.unprompted)
            row("不该做的没有做", r.noWrongfulAction)
            ForEach(ComfortDecision.allCases, id: \.self) { d in row("期望 \(d.rawValue)", r.byDecision[d] ?? ComfortReport.Tally()) }
            LabeledContent("每次工具调用", value: String(format: "%.2f", r.callsPerRun))
            LabeledContent("被规则拦下", value: "\(r.blocked)")
            LabeledContent("第一次回复的无依据说法", value: "\(r.firstReplyClaims)")
            LabeledContent("纠正后仍无依据", value: "\(r.uncorrectedClaims)")
            LabeledContent("动作回复超过两句", value: "\(r.tooLong)")
            LabeledContent("纠正回合超时", value: "\(r.correctionStalled)")
            LabeledContent("次数不足的句子（不算 3 次都过）", value: "\(r.shortCases.count)")
        }
        if eval.reportIsTrial {
            Section("试跑回复（\(eval.trialRuns.count)）") {
                ForEach(Array(eval.trialRuns.enumerated()), id: \.offset) { _, run in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(run.caseID) · \(ComfortScorer.decision(run).rawValue)\(run.problem.map { " · \($0.rawValue)" } ?? "")")
                            .font(.footnote.monospaced())
                        if let c = ComfortCases.all.first(where: { $0.id == run.caseID }) { Text("「\(c.sentence)」").font(.footnote) }
                        Text(run.reply.isEmpty ? "（没有回复）" : run.reply).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section("时间 ms（中位 / 90% / 最慢）") {
            ForEach(ComfortStages.Stage.allCases, id: \.self) { stage in
                LabeledContent(stageTitle(stage),
                               value: "舒适 \(r.stagesComfort[stage]?.text ?? "—")  全部 \(r.stagesAll[stage]?.text ?? "—")")
                    .font(.footnote.monospacedDigit())
            }
        }
        Section("失败原因") {
            ForEach(r.causes.sorted { $0.key < $1.key }, id: \.key) { cause, count in
                LabeledContent(cause, value: "\(count)").font(.footnote.monospaced())
            }
        }
        if !r.blocks.isEmpty {
            Section("被拦下（\(r.blocks.count)）") {
                ForEach(Array(r.blocks.enumerated()), id: \.offset) { _, b in
                    Text("\(b.caseID) #\(b.attempt) · \(b.tool) · \(b.rule)").font(.footnote.monospaced())
                }
            }
        }
        Section("失败（\(r.failures.count)）") {
            ForEach(Array(r.failures.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.code).font(.footnote.monospaced())
                    if let c = ComfortCases.all.first(where: { $0.id == f.caseID }) {
                        Text("「\(c.sentence)」").font(.footnote)
                    }
                    Text(f.reply.isEmpty ? "（没有回复）" : f.reply).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// §16 item 7: model minus table per case, same build only; item 14 bars are PROPOSED.
    @ViewBuilder
    private var comparisonSection: some View {
        if let t = eval.saved[.table], let m = eval.saved[.model] {
            Section("对比（模型 − 固定场景表）") {
                LabeledContent("固定场景表", value: "\(t.build) · \(t.date)").font(.footnote)
                LabeledContent("模型决定", value: "\(m.build) · \(m.date)").font(.footnote)
                if let cmp = ComfortComparison(table: t, model: m) {
                    LabeledContent("平均差（\(cmp.cases) 条）",
                                   value: String(format: "%+.1f 分，95%% 区间 %+.1f … %+.1f", cmp.meanPoints, cmp.lowPoints, cmp.highPoints))
                    if cmp.noVisibleDifference { Text("看不出差别").font(.footnote.bold()) }
                    let bars = cmp.bars(table: t, model: m)
                    Text("门槛（待定）：纠正后无依据 0 \(mark(bars.noUncorrectedClaims))；不该做的没做 ≥95% \(mark(bars.noWrongfulAction95))；区间下限 ≥ −5 分 \(mark(bars.overallWithinFive))；舒适第一声中位慢不超过 1 s \(mark(bars.medianWithinOneSecond))；90% < 3 s \(mark(bars.p90UnderThreeSeconds))；最慢 \(m.comfortFirstAudioWorst.map { "\($0) ms" } ?? "—")；第一次回复无依据 \(m.firstReplyClaims)；车上第 8 行另测")
                        .font(.footnote)
                    ForEach(cmp.differing, id: \.caseID) { d in
                        LabeledContent(d.caseID, value: String(format: "%+.0f", d.points)).font(.footnote.monospaced())
                    }
                } else {
                    Text("不是同一个版本，不对比。").font(.footnote)
                }
            }
        }
    }

    private func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }

    private func stageTitle(_ s: ComfortStages.Stage) -> String {
        switch s {
        case .firstEvent: "发送→第一个事件"
        case .firstTool: "发送→第一次工具调用"
        case .toolToAudio: "工具结果→第一声"
        case .firstAudio: "发送→第一声"
        case .answerDone: "发送→回复结束"
        }
    }

    private func row(_ title: String, _ t: ComfortReport.Tally) -> some View {
        LabeledContent(title, value: "\(t.passed)/\(t.total)  \(t.percent)%")
    }
}
