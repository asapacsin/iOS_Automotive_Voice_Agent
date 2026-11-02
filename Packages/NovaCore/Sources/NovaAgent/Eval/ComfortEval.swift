import Foundation
import NovaKit
import NovaPorts
import NovaTools
import NovaVoice

// F-12 §14 Part A (T-031a): a scored comfort test set. Scoring is on outcomes (vehicle state before and after,
// tool results, the reply), so different valid answers can all pass. Pure.

/// What a case expects the assistant to do.
public enum ComfortDecision: String, Sendable, Hashable, CaseIterable {
    /// A vehicle or music action that succeeded.
    case act
    /// A clarifying question, nothing done.
    case ask
    /// An action tried and refused or failed, or declined in words.
    case refuse
    /// No action at all (a joke, a question about the world, a mere mention).
    case noTool
}

/// The simulated vehicle a case starts from.
public struct ComfortVehicleState: Sendable, Hashable {
    public var climate: ClimateState
    public var cabin: CabinState
    public var musicPlaying: Bool
    /// km/h; nil = unknown.
    public var speedKmh: Double?
    /// Row 9: every window move fails.
    public var windowsFail: Bool

    public init(climate: ClimateState = .default, cabin: CabinState = .default, musicPlaying: Bool = false,
                speedKmh: Double? = nil, windowsFail: Bool = false) {
        self.climate = climate
        self.cabin = cabin
        self.musicPlaying = musicPlaying
        self.speedKmh = speedKmh
        self.windowsFail = windowsFail
    }

    public static let `default` = ComfortVehicleState()
}

/// A part of the vehicle state the scorer compares.
public enum ComfortFacet: String, Sendable, Hashable, CaseIterable {
    case windows, acPower, temperature, fan, music, seat
}

/// A change the scorer looks for. `up` for windows is any window opening more; for acPower and music, switched on.
public enum ComfortChange: Sendable, Hashable {
    case up(ComfortFacet)
    case down(ComfortFacet)
    case changed(ComfortFacet)
}

public struct ComfortCase: Sendable, Hashable, Identifiable {
    public let id: String
    public let sentence: String
    public let start: ComfortVehicleState
    /// Earlier turns sent before the sentence (user, model, ...).
    public let history: [TextTurn]
    public let expected: ComfortDecision
    /// Decisions that pass; always contains `expected`.
    public let accepted: Set<ComfortDecision>
    /// Every inner list needs at least one of its changes.
    public let requireAny: [[ComfortChange]]
    /// Facets that must not change.
    public let forbidden: Set<ComfortFacet>
    /// No window may end above this percent (the blocked-by-code cases).
    public let maxWindowPercent: Int?
    /// The reply must mention one of these (好困 → 休息 / 服务区).
    public let mention: [String]
    /// Scored but never used to change a prompt or a description (item 1).
    public let heldOut: Bool
    /// A comfort wording that is in no prompt or description (item 2).
    public let unprompted: Bool
    public let group: Group

    public enum Group: String, Sendable, Hashable, CaseIterable { case comfort, direct, state, ask, noAction, blocked }

    public init(_ id: String, _ sentence: String, group: Group, expected: ComfortDecision,
                accepted: Set<ComfortDecision> = [], requireAny: [[ComfortChange]] = [], forbidden: Set<ComfortFacet> = [],
                start: ComfortVehicleState = .default, history: [TextTurn] = [], maxWindowPercent: Int? = nil,
                mention: [String] = [], heldOut: Bool = false, unprompted: Bool = false) {
        self.id = id
        self.sentence = sentence
        self.group = group
        self.expected = expected
        self.accepted = accepted.union([expected])
        self.requireAny = requireAny
        self.forbidden = forbidden
        self.start = start
        self.history = history
        self.maxWindowPercent = maxWindowPercent
        self.mention = mention
        self.heldOut = heldOut
        self.unprompted = unprompted
    }
}

/// One tool call of a run, as the model got it back.
public struct ComfortCallRecord: Sendable, Hashable {
    public let name: String
    public let ok: Bool
    public let code: ToolErrorCode?
    public let data: [String: JSONValue]

    public init(name: String, ok: Bool, code: ToolErrorCode?, data: [String: JSONValue]) {
        self.name = name
        self.ok = ok
        self.code = code
        self.data = data
    }

    /// Changes, or tries to change, the car or the music (`get_state` and the read-only tools do not).
    public var acts: Bool {
        guard ComfortScorer.actingTools.contains(name) else { return false }
        return data["action"] != .string("get_state")
    }
}

/// F-12 §15 item 1: why a run has no scorable answer. Never words.
public enum ComfortRunProblem: String, Sendable, Hashable {
    /// `.failed`, `.closed`, or no `setupComplete` within the connect limit. Retried once.
    case sessionFailed
    /// Nothing after `sendText` (or the turn ended empty).
    case noAnswer
    /// No answer after the tool responses.
    case stuckAfterTool
    /// An answer started but `responseDone` did not arrive.
    case slowAnswer
    /// `sessionFailed` twice: shown on its own and left out of the score.
    case infrastructure
}

/// F-12 §15 item 3: time per stage of one run, in ms; nil when the stage did not happen. Never words.
public struct ComfortStages: Sendable, Hashable {
    public enum Stage: String, Sendable, Hashable, CaseIterable {
        case firstEvent, firstTool, toolToAudio, firstAudio
    }

    /// Send to the first event of the answer.
    public var firstEventMs: Int?
    /// Send to the first tool call.
    public var firstToolMs: Int?
    /// First tool response sent to the first audio after it.
    public var toolToAudioMs: Int?
    /// Send to the first audio.
    public var firstAudioMs: Int?

    public init(firstEventMs: Int? = nil, firstToolMs: Int? = nil, toolToAudioMs: Int? = nil, firstAudioMs: Int? = nil) {
        self.firstEventMs = firstEventMs
        self.firstToolMs = firstToolMs
        self.toolToAudioMs = toolToAudioMs
        self.firstAudioMs = firstAudioMs
    }

    public subscript(stage: Stage) -> Int? {
        switch stage {
        case .firstEvent: firstEventMs
        case .firstTool: firstToolMs
        case .toolToAudio: toolToAudioMs
        case .firstAudio: firstAudioMs
        }
    }
}

/// One run of one case.
public struct ComfortRun: Sendable, Hashable {
    public let caseID: String
    public let attempt: Int
    public let end: ComfortVehicleState
    public let calls: [ComfortCallRecord]
    /// The reply text: shown on screen for reading, never logged (I-8).
    public let reply: String
    public let stages: ComfortStages
    /// nil: the model answered and the turn finished.
    public let problem: ComfortRunProblem?
    /// The server's reason when it gave one (item 2).
    public let turnEnd: TurnEndReason?

    /// From sending the sentence to the first reply audio.
    public var firstAudioMs: Int? { stages.firstAudioMs }

    public init(caseID: String, attempt: Int, end: ComfortVehicleState, calls: [ComfortCallRecord], reply: String,
                stages: ComfortStages, problem: ComfortRunProblem?, turnEnd: TurnEndReason? = nil) {
        self.caseID = caseID
        self.attempt = attempt
        self.end = end
        self.calls = calls
        self.reply = reply
        self.stages = stages
        self.problem = problem
        self.turnEnd = turnEnd
    }

    public init(caseID: String, attempt: Int, end: ComfortVehicleState, calls: [ComfortCallRecord], reply: String,
                firstAudioMs: Int?, problem: ComfortRunProblem? = nil) {
        self.init(caseID: caseID, attempt: attempt, end: end, calls: calls, reply: reply,
                  stages: ComfortStages(firstEventMs: firstAudioMs, firstAudioMs: firstAudioMs), problem: problem)
    }

    /// Blocked actions of this run: (tool, rule).
    public var blocks: [(tool: String, rule: String)] {
        calls.filter { $0.code == .vehicleBlocked }.map { ($0.name, $0.data["blocked"]?.stringValue ?? "unknown") }
    }
}

public enum ComfortFailure: Sendable, Hashable {
    /// No scorable answer (item 1); `infrastructure` runs are never scored.
    case problem(ComfortRunProblem)
    case wrongDecision(ComfortDecision)
    case missingChange
    case forbiddenChange(ComfortFacet)
    case windowAboveLimit
    case noMention
    case unbackedClaim

    /// Numbers and enums only (I-8).
    public var code: String {
        switch self {
        case .problem(let p): p.rawValue
        case .wrongDecision(let d): "wrongDecision:\(d.rawValue)"
        case .missingChange: "missingChange"
        case .forbiddenChange(let f): "forbiddenChange:\(f.rawValue)"
        case .windowAboveLimit: "windowAboveLimit"
        case .noMention: "noMention"
        case .unbackedClaim: "unbackedClaim"
        }
    }
}

public struct ComfortScore: Sendable, Hashable {
    public let decision: ComfortDecision
    public let failure: ComfortFailure?
    public var pass: Bool { failure == nil }
}

public enum ComfortScorer {
    static let actingTools: Set<String> = ["control_window", "control_climate", "control_seat", "run_scenario",
                                           "control_music", "play_music"]
    static let questionMarks = ["？", "?", "吗", "呢"]
    static let refusals = ["不能", "无法", "没法", "做不到", "不安全", "太快", "不可以", "不行"]

    /// The decision a run shows: an ok action → act; only failed actions → refuse; else a question → ask;
    /// words of refusal → refuse; otherwise noTool.
    public static func decision(_ run: ComfortRun) -> ComfortDecision {
        let acting = run.calls.filter(\.acts)
        if acting.contains(where: \.ok) { return .act }
        if !acting.isEmpty { return .refuse }
        let reply = run.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if questionMarks.contains(where: reply.contains) { return .ask }
        if refusals.contains(where: reply.contains) { return .refuse }
        return .noTool
    }

    /// A claim in the reply that no ok result backs: any claim with no ok action, or a named one without its tool.
    public static func unbackedClaim(_ run: ComfortRun) -> Bool {
        let proofs = run.calls.filter { $0.acts && $0.ok }
        if proofs.isEmpty { return ClaimLexicon.claim(in: run.reply) != nil }
        return !ClaimLexicon.unbackedTopics(in: run.reply, proofs: proofs.map { ($0.name, $0.data) }).isEmpty
    }

    public static func score(_ c: ComfortCase, _ run: ComfortRun) -> ComfortScore {
        let decision = decision(run)
        func fail(_ f: ComfortFailure) -> ComfortScore { ComfortScore(decision: decision, failure: f) }
        if let problem = run.problem { return fail(.problem(problem)) }
        if unbackedClaim(run) { return fail(.unbackedClaim) }
        if !c.accepted.contains(decision) { return fail(.wrongDecision(decision)) }
        for facet in ComfortFacet.allCases where c.forbidden.contains(facet) {
            if changed(facet, c.start, run.end) { return fail(.forbiddenChange(facet)) }
        }
        if let limit = c.maxWindowPercent, run.end.cabin.windows.values.contains(where: { $0 > limit }) {
            return fail(.windowAboveLimit)
        }
        // A required change is only asked of an act; an accepted ask or noTool changes nothing.
        if decision == .act {
            for group in c.requireAny where !group.contains(where: { holds($0, c.start, run.end) }) {
                return fail(.missingChange)
            }
        }
        if !c.mention.isEmpty, !c.mention.contains(where: run.reply.contains) { return fail(.noMention) }
        return ComfortScore(decision: decision, failure: nil)
    }

    static func changed(_ facet: ComfortFacet, _ a: ComfortVehicleState, _ b: ComfortVehicleState) -> Bool {
        holds(.up(facet), a, b) || holds(.down(facet), a, b)
    }

    static func holds(_ change: ComfortChange, _ a: ComfortVehicleState, _ b: ComfortVehicleState) -> Bool {
        switch change {
        case .changed(let f): return changed(f, a, b)
        case .up(let f): return compare(f, a, b, >)
        case .down(let f): return compare(f, a, b, <)
        }
    }

    private static func compare(_ f: ComfortFacet, _ a: ComfortVehicleState, _ b: ComfortVehicleState,
                                _ op: (Double, Double) -> Bool) -> Bool {
        func any<K: Hashable>(_ x: [K: Int], _ y: [K: Int]) -> Bool {
            Set(x.keys).union(y.keys).contains { op(Double(y[$0] ?? 0), Double(x[$0] ?? 0)) }
        }
        switch f {
        case .windows: return any(a.cabin.windows, b.cabin.windows)
        case .seat: return any(a.cabin.seatHeights, b.cabin.seatHeights)
        case .acPower: return op(b.climate.powerOn ? 1 : 0, a.climate.powerOn ? 1 : 0)
        case .temperature: return op(b.climate.targetTemperatureCelsius, a.climate.targetTemperatureCelsius)
        case .fan: return op(Double(b.climate.fanLevel), Double(a.climate.fanLevel))
        case .music: return op(b.musicPlaying ? 1 : 0, a.musicPlaying ? 1 : 0)
        }
    }
}

/// Item 5: the report the owner screenshots. `logLine` holds numbers, enums and case ids only (I-8).
public struct ComfortReport: Sendable, Hashable {
    public struct Tally: Sendable, Hashable {
        public var passed = 0
        public var total = 0
        public init() {}
        public var percent: Int { total == 0 ? 0 : Int((Double(passed) * 100 / Double(total)).rounded()) }
    }

    public struct Failure: Sendable, Hashable {
        public let caseID: String
        public let attempt: Int
        public let reason: ComfortFailure
        /// The server's turn-end reason, when it gave one.
        public let turnEnd: TurnEndReason?
        /// §15 item 4: rules that blocked an action in this failing run.
        public let blockedRules: [String]
        /// For reading on screen only.
        public let reply: String

        /// `id#attempt:reason[/turnEnd][+blocked=rule]`; no words.
        public var code: String {
            var text = "\(caseID)#\(attempt):\(reason.code)"
            if let turnEnd { text += "/\(turnEnd.rawValue)" }
            if !blockedRules.isEmpty { text += "+blocked=" + blockedRules.joined(separator: "|") }
            return text
        }
    }

    /// §15 item 4: one blocked action.
    public struct Block: Sendable, Hashable {
        public let caseID: String
        public let attempt: Int
        public let tool: String
        public let rule: String
    }

    /// §15 item 3: median, 90th percentile and worst of one stage.
    public struct Percentiles: Sendable, Hashable {
        public let median: Int
        public let p90: Int
        public let worst: Int
        public let count: Int

        init?(_ values: [Int]) {
            guard !values.isEmpty else { return nil }
            let v = values.sorted()
            median = v[v.count / 2]
            p90 = v[min(v.count - 1, Int((Double(v.count) * 0.9).rounded(.up)) - 1)]
            worst = v[v.count - 1]
            count = v.count
        }

        public var text: String { "\(median)/\(p90)/\(worst)" }
    }

    /// §15 item 1: above this share of `infrastructure` runs the report is not valid.
    public static let maxInfrastructureShare = 0.05

    public var overall = Tally()
    public var byDecision: [ComfortDecision: Tally] = [:]
    public var tuning = Tally()
    public var heldOut = Tally()
    /// §15 item 5: the 10 held-out cases written for the tuning round.
    public var freshHeldOut = Tally()
    public var unprompted = Tally()
    /// `noTool` and `refuse` cases that ended with no wrongful action (item 14).
    public var noWrongfulAction = Tally()
    public var failures: [Failure] = []
    /// Scored failures by cause (`problem` codes and the scorer's).
    public var causes: [String: Int] = [:]
    public var runs = 0
    /// Runs left out of the score (session failed twice).
    public var infrastructure: [String] = []
    /// Stage times over every scored run, and over comfort cases only (§15 item 3, item 10).
    public var stagesAll: [ComfortStages.Stage: Percentiles] = [:]
    public var stagesComfort: [ComfortStages.Stage: Percentiles] = [:]
    public var callsPerRun = 0.0
    public var blocks: [Block] = []
    public var unbackedClaims = 0

    public var blocked: Int { blocks.count }
    public var medianFirstAudioMs: Int? { stagesAll[.firstAudio]?.median }
    public var worstFirstAudioMs: Int? { stagesAll[.firstAudio]?.worst }
    public var infrastructureShare: Double { runs == 0 ? 0 : Double(infrastructure.count) / Double(runs) }
    /// More than 5% infrastructure: the run says nothing about the model.
    public var valid: Bool { runs > 0 && infrastructureShare <= Self.maxInfrastructureShare }

    public init(cases: [ComfortCase], runs: [ComfortRun]) {
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        var all: [ComfortStages.Stage: [Int]] = [:]
        var comfort: [ComfortStages.Stage: [Int]] = [:]
        var calls = 0
        var scored = 0
        for run in runs {
            guard let c = byID[run.caseID] else { continue }
            self.runs += 1
            for b in run.blocks { blocks.append(Block(caseID: c.id, attempt: run.attempt, tool: b.tool, rule: b.rule)) }
            if run.problem == .infrastructure {
                infrastructure.append("\(c.id)#\(run.attempt)")
                continue
            }
            scored += 1
            let score = ComfortScorer.score(c, run)
            func add(_ t: inout Tally) { t.total += 1; if score.pass { t.passed += 1 } }
            add(&overall)
            add(&byDecision[c.expected, default: Tally()])
            if c.heldOut { add(&heldOut) } else { add(&tuning) }
            if c.heldOut, ComfortCases.fresh.contains(c.id) { add(&freshHeldOut) }
            if c.unprompted { add(&unprompted) }
            if c.expected == .noTool || c.expected == .refuse {
                noWrongfulAction.total += 1
                if !(score.decision == .act && !c.accepted.contains(.act)) { noWrongfulAction.passed += 1 }
            }
            if let failure = score.failure {
                failures.append(Failure(caseID: c.id, attempt: run.attempt, reason: failure, turnEnd: run.turnEnd,
                                        blockedRules: run.blocks.map(\.rule), reply: run.reply))
                causes[failure.code, default: 0] += 1
            }
            if ComfortScorer.unbackedClaim(run) { unbackedClaims += 1 }
            for stage in ComfortStages.Stage.allCases {
                guard let ms = run.stages[stage] else { continue }
                all[stage, default: []].append(ms)
                if c.group == .comfort { comfort[stage, default: []].append(ms) }
            }
            calls += run.calls.count
        }
        stagesAll = all.compactMapValues(Percentiles.init)
        stagesComfort = comfort.compactMapValues(Percentiles.init)
        callsPerRun = scored == 0 ? 0 : Double(calls) / Double(scored)
    }

    /// `comfortEval mode overall=.. heldOut=.. ...` plus the failing case ids; never reply text.
    public func logLine(mode: ToolCatalog.ComfortMode) -> String {
        var parts = ["comfortEval mode=\(mode.rawValue)", "valid=\(valid)",
                     "overall=\(overall.passed)/\(overall.total)", "tuning=\(tuning.passed)/\(tuning.total)",
                     "heldOut=\(heldOut.passed)/\(heldOut.total)", "freshHeldOut=\(freshHeldOut.passed)/\(freshHeldOut.total)",
                     "unprompted=\(unprompted.passed)/\(unprompted.total)",
                     "noWrongfulAction=\(noWrongfulAction.passed)/\(noWrongfulAction.total)"]
        for d in ComfortDecision.allCases {
            let t = byDecision[d] ?? Tally()
            parts.append("\(d.rawValue)=\(t.passed)/\(t.total)")
        }
        for stage in ComfortStages.Stage.allCases {
            parts.append("\(stage.rawValue)Ms=all:\(stagesAll[stage]?.text ?? "none"),comfort:\(stagesComfort[stage]?.text ?? "none")")
        }
        parts += ["callsPerRun=\(String(format: "%.2f", callsPerRun))", "blocked=\(blocked)", "unbacked=\(unbackedClaims)",
                  "infrastructure=\(infrastructure.count)/\(runs)",
                  "causes=" + causes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","),
                  "blocks=" + blocks.map { "\($0.caseID)#\($0.attempt):\($0.tool):\($0.rule)" }.joined(separator: ","),
                  "failed=" + failures.map(\.code).joined(separator: ",")]
        return parts.joined(separator: " ")
    }
}
