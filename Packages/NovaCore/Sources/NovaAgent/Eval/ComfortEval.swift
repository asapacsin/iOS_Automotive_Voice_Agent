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
    /// §16 item 9: the app left the foreground during the run; repeated and not scored.
    case interrupted
}

/// F-12 §15 item 3: time per stage of one run, in ms; nil when the stage did not happen. Never words.
public struct ComfortStages: Sendable, Hashable {
    public enum Stage: String, Sendable, Hashable, CaseIterable {
        case firstEvent, firstTool, toolToAudio, firstAudio, answerDone
    }

    /// Send to the first event of the answer.
    public var firstEventMs: Int?
    /// Send to the first tool call.
    public var firstToolMs: Int?
    /// First tool response sent to the first audio after it.
    public var toolToAudioMs: Int?
    /// Send to the first audio.
    public var firstAudioMs: Int?
    /// §16 item 1: send to the end of the reply (`audioDone` or `responseDone`, whichever is first).
    public var answerDoneMs: Int?

    public init(firstEventMs: Int? = nil, firstToolMs: Int? = nil, toolToAudioMs: Int? = nil, firstAudioMs: Int? = nil,
                answerDoneMs: Int? = nil) {
        self.firstEventMs = firstEventMs
        self.firstToolMs = firstToolMs
        self.toolToAudioMs = toolToAudioMs
        self.firstAudioMs = firstAudioMs
        self.answerDoneMs = answerDoneMs
    }

    public subscript(stage: Stage) -> Int? {
        switch stage {
        case .firstEvent: firstEventMs
        case .firstTool: firstToolMs
        case .toolToAudio: toolToAudioMs
        case .firstAudio: firstAudioMs
        case .answerDone: answerDoneMs
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
    /// §16 item 10: the first reply made an unbacked claim, so the runner sent a correction; `reply` is the final one.
    public let firstReplyClaim: Bool
    /// The correction turn did not finish within its limit; the final state is scored as it is.
    public let correctionStalled: Bool

    /// From sending the sentence to the first reply audio.
    public var firstAudioMs: Int? { stages.firstAudioMs }

    public init(caseID: String, attempt: Int, end: ComfortVehicleState, calls: [ComfortCallRecord], reply: String,
                stages: ComfortStages, problem: ComfortRunProblem?, turnEnd: TurnEndReason? = nil, firstReplyClaim: Bool = false,
                correctionStalled: Bool = false) {
        self.firstReplyClaim = firstReplyClaim
        self.correctionStalled = correctionStalled
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
    static let refusals = ["不能", "无法", "没法", "做不到", "不安全", "太快", "不可以", "不行"]

    /// The decision a run shows: an ok action → act; only failed actions → refuse; else a question → ask;
    /// words of refusal → refuse; otherwise noTool.
    public static func decision(_ run: ComfortRun) -> ComfortDecision {
        let acting = run.calls.filter(\.acts)
        if acting.contains(where: \.ok) { return .act }
        if !acting.isEmpty { return .refuse }
        return textDecision(run.reply)
    }

    /// §16 item 2: the reply's sentences, split on 。！？!? and newlines.
    public static func sentences(_ reply: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in reply {
            current.append(ch)
            if "。！？!?\n".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        return out
    }

    /// §16 item 2: `ask` when the last sentence is a question; `refuse` when the first or last sentence refuses.
    public static func textDecision(_ reply: String) -> ComfortDecision {
        let parts = sentences(reply)
        guard let last = parts.last else { return .noTool }
        let bare = last.trimmingCharacters(in: CharacterSet(charactersIn: "。！!.，, \n"))
        if bare.hasSuffix("？") || bare.hasSuffix("?") || bare.hasSuffix("吗") || bare.hasSuffix("呢") { return .ask }
        if let first = parts.first, refusals.contains(where: { first.contains($0) || last.contains($0) }) { return .refuse }
        return .noTool
    }

    /// §16 item 8: an `act` run that says more than two sentences.
    public static func tooLong(_ run: ComfortRun) -> Bool {
        decision(run) == .act && sentences(run.reply).count > 2
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
    /// §16 item 5: the 20 held-out cases written for T-031e; with overall, the score that decides.
    public var newHeldOut = Tally()
    public var unprompted = Tally()
    /// `noTool` and `refuse` cases that ended with no wrongful action (item 14).
    public var noWrongfulAction = Tally()
    /// §16 item 6: cases whose every scored run passed (pass^3), overall and by expected decision.
    public var allRunsPass = Tally()
    public var allRunsPassByDecision: [ComfortDecision: Tally] = [:]
    /// Per case: pass of each scored run, in order. Disputed cases are left out.
    public var perCase: [String: [Bool]] = [:]
    public var failures: [Failure] = []
    /// Scored failures by cause (`problem` codes and the scorer's).
    public var causes: [String: Int] = [:]
    public var runs = 0
    /// Runs left out of the score (session failed twice).
    public var infrastructure: [String] = []
    /// §16 item 9: runs repeated because the app left the foreground.
    public var interrupted = 0
    /// §16 item 4: cases shown as 有争议 and not scored.
    public var disputed: [String] = []
    /// Stage times over every scored run, and over comfort cases only (§15 item 3, item 10).
    public var stagesAll: [ComfortStages.Stage: Percentiles] = [:]
    public var stagesComfort: [ComfortStages.Stage: Percentiles] = [:]
    public var callsPerRun = 0.0
    public var blocks: [Block] = []
    /// §16 item 10: runs whose first reply made an unbacked claim, and runs whose final reply still does.
    public var firstReplyClaims = 0
    public var uncorrectedClaims = 0
    /// §16 item 8: `act` runs of more than two sentences. Reported, not a failure; knowledge answers not counted.
    public var tooLong = 0
    /// Correction turns that stalled (shown, not a failure).
    public var correctionStalled = 0
    /// Cases with fewer scored runs than `attempts` (infrastructure or still interrupted): never pass^3.
    public var shortCases: [String] = []

    public var blocked: Int { blocks.count }
    /// The final reply's unbacked claims (kept for the earlier screens).
    public var unbackedClaims: Int { uncorrectedClaims }
    public var medianFirstAudioMs: Int? { stagesAll[.firstAudio]?.median }
    public var worstFirstAudioMs: Int? { stagesAll[.firstAudio]?.worst }
    public var infrastructureShare: Double { runs == 0 ? 0 : Double(infrastructure.count) / Double(runs) }
    /// More than 5% infrastructure: the run says nothing about the model.
    public var valid: Bool { runs > 0 && infrastructureShare <= Self.maxInfrastructureShare }

    public init(cases: [ComfortCase], runs: [ComfortRun], disputed: Set<String> = ComfortCases.disputed,
                attempts: Int? = nil) {
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        var all: [ComfortStages.Stage: [Int]] = [:]
        var comfort: [ComfortStages.Stage: [Int]] = [:]
        var calls = 0
        var scored = 0
        self.disputed = cases.map(\.id).filter(disputed.contains)
        for run in runs {
            guard let c = byID[run.caseID] else { continue }
            if run.problem == .interrupted { interrupted += 1; continue }
            if disputed.contains(c.id) { continue }
            self.runs += 1
            for b in run.blocks { blocks.append(Block(caseID: c.id, attempt: run.attempt, tool: b.tool, rule: b.rule)) }
            if run.problem == .infrastructure {
                infrastructure.append("\(c.id)#\(run.attempt)")
                continue
            }
            scored += 1
            let score = ComfortScorer.score(c, run)
            perCase[c.id, default: []].append(score.pass)
            func add(_ t: inout Tally) { t.total += 1; if score.pass { t.passed += 1 } }
            add(&overall)
            add(&byDecision[c.expected, default: Tally()])
            if c.heldOut { add(&heldOut) } else { add(&tuning) }
            if c.heldOut, ComfortCases.fresh.contains(c.id) { add(&freshHeldOut) }
            if c.heldOut, ComfortCases.newest.contains(c.id) { add(&newHeldOut) }
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
            if run.firstReplyClaim { firstReplyClaims += 1 }
            if run.correctionStalled { correctionStalled += 1 }
            if ComfortScorer.unbackedClaim(run) { uncorrectedClaims += 1 }
            if c.group != .noAction, ComfortScorer.tooLong(run) { tooLong += 1 }
            for stage in ComfortStages.Stage.allCases {
                guard let ms = run.stages[stage] else { continue }
                all[stage, default: []].append(ms)
                if c.group == .comfort { comfort[stage, default: []].append(ms) }
            }
            calls += run.calls.count
        }
        let expected = attempts ?? perCase.values.map(\.count).max() ?? 0
        for (id, passes) in perCase.sorted(by: { $0.key < $1.key }) {
            guard let c = byID[id] else { continue }
            if passes.count < expected { shortCases.append(id); continue }
            let ok = passes.allSatisfy { $0 }
            allRunsPass.total += 1
            allRunsPassByDecision[c.expected, default: Tally()].total += 1
            if ok {
                allRunsPass.passed += 1
                allRunsPassByDecision[c.expected, default: Tally()].passed += 1
            }
        }
        stagesAll = all.compactMapValues(Percentiles.init)
        stagesComfort = comfort.compactMapValues(Percentiles.init)
        callsPerRun = scored == 0 ? 0 : Double(calls) / Double(scored)
    }

    /// §16 item 9: the summary, each failure and each block as separate lines; numbers, enums and ids only (I-8).
    public func logLines(mode: ToolCatalog.ComfortMode) -> [String] {
        [logLine(mode: mode)]
            + failures.map { "comfortEvalFailure mode=\(mode.rawValue) \($0.code)" }
            + blocks.map { "comfortEvalBlock mode=\(mode.rawValue) \($0.caseID)#\($0.attempt) \($0.tool) \($0.rule)" }
    }

    /// The summary line alone (no failure or block lists, so it is never cut off).
    public func logLine(mode: ToolCatalog.ComfortMode) -> String {
        var parts = ["comfortEval mode=\(mode.rawValue)", "valid=\(valid)",
                     "overall=\(overall.passed)/\(overall.total)", "tuning=\(tuning.passed)/\(tuning.total)",
                     "heldOut=\(heldOut.passed)/\(heldOut.total)", "freshHeldOut=\(freshHeldOut.passed)/\(freshHeldOut.total)",
                     "newHeldOut=\(newHeldOut.passed)/\(newHeldOut.total)",
                     "unprompted=\(unprompted.passed)/\(unprompted.total)",
                     "noWrongfulAction=\(noWrongfulAction.passed)/\(noWrongfulAction.total)",
                     "passAll=\(allRunsPass.passed)/\(allRunsPass.total)"]
        for d in ComfortDecision.allCases {
            let t = byDecision[d] ?? Tally()
            parts.append("\(d.rawValue)=\(t.passed)/\(t.total)")
        }
        for stage in ComfortStages.Stage.allCases {
            parts.append("\(stage.rawValue)Ms=all:\(stagesAll[stage]?.text ?? "none"),comfort:\(stagesComfort[stage]?.text ?? "none")")
        }
        parts += ["callsPerRun=\(String(format: "%.2f", callsPerRun))", "blocked=\(blocked)",
                  "firstReplyClaims=\(firstReplyClaims)", "uncorrectedClaims=\(uncorrectedClaims)", "tooLong=\(tooLong)", "correctionStalled=\(correctionStalled)",
                  "shortCases=\(shortCases.count)",
                  "infrastructure=\(infrastructure.count)/\(runs)", "interrupted=\(interrupted)", "disputed=\(disputed.count)",
                  "causes=" + causes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")]
        return parts.joined(separator: " ")
    }
}

/// §16 item 7: what is kept of the latest report per mode, in a local file (never logged), so both survive a restart.
public struct ComfortSummary: Codable, Sendable, Hashable {
    public let mode: String
    public let build: String
    public let date: String
    /// Per case: passes and scored runs.
    public let perCase: [String: [Bool]]
    public let noWrongfulPassed: Int
    public let noWrongfulTotal: Int
    public let uncorrectedClaims: Int
    public let firstReplyClaims: Int
    public let comfortFirstAudioMedian: Int?
    public let comfortFirstAudioP90: Int?
    public let comfortFirstAudioWorst: Int?

    public init(report: ComfortReport, mode: ToolCatalog.ComfortMode, build: String, date: String) {
        self.mode = mode.rawValue
        self.build = build
        self.date = date
        perCase = report.perCase
        noWrongfulPassed = report.noWrongfulAction.passed
        noWrongfulTotal = report.noWrongfulAction.total
        uncorrectedClaims = report.uncorrectedClaims
        firstReplyClaims = report.firstReplyClaims
        comfortFirstAudioMedian = report.stagesComfort[.firstAudio]?.median
        comfortFirstAudioP90 = report.stagesComfort[.firstAudio]?.p90
        comfortFirstAudioWorst = report.stagesComfort[.firstAudio]?.worst
    }

    func rate(_ id: String) -> Double? {
        guard let p = perCase[id], !p.isEmpty else { return nil }
        return Double(p.filter { $0 }.count) / Double(p.count)
    }
}

/// §16 item 7: model minus table per case (Miller): mean difference with a 95% interval from its standard error.
/// Only reports of the same build are compared; totals alone are never compared.
public struct ComfortComparison: Sendable, Hashable {
    public struct CaseDifference: Sendable, Hashable {
        public let caseID: String
        /// Model pass rate minus table pass rate, in points.
        public let points: Double
    }

    /// In points (percentage of runs passed).
    public let meanPoints: Double
    public let lowPoints: Double
    public let highPoints: Double
    public let cases: Int
    /// Every case where the versions differ.
    public let differing: [CaseDifference]
    /// 「看不出差别」: the interval includes zero.
    public var noVisibleDifference: Bool { lowPoints <= 0 && highPoints >= 0 }

    /// nil when the builds differ or no case is in both.
    public init?(table: ComfortSummary, model: ComfortSummary) {
        guard table.build == model.build, table.mode == ToolCatalog.ComfortMode.table.rawValue,
              model.mode == ToolCatalog.ComfortMode.model.rawValue else { return nil }
        let ids = Set(table.perCase.keys).intersection(model.perCase.keys).sorted()
        let diffs: [(String, Double)] = ids.compactMap { id in
            guard let m = model.rate(id), let t = table.rate(id) else { return nil }
            return (id, (m - t) * 100)
        }
        guard !diffs.isEmpty else { return nil }
        let n = Double(diffs.count)
        let mean = diffs.map(\.1).reduce(0, +) / n
        let variance = diffs.count > 1 ? diffs.map { ($0.1 - mean) * ($0.1 - mean) }.reduce(0, +) / (n - 1) : 0
        let se = (variance / n).squareRoot()
        meanPoints = mean
        lowPoints = mean - 1.96 * se
        highPoints = mean + 1.96 * se
        cases = diffs.count
        differing = diffs.filter { $0.1 != 0 }.map { CaseDifference(caseID: $0.0, points: $0.1) }
    }

    /// §16 item 14 bars, PROPOSED until the owner has seen the numbers. Device row 8 is not part of this check.
    public struct Bars: Sendable, Hashable {
        public let noUncorrectedClaims: Bool
        public let noWrongfulAction95: Bool
        public let overallWithinFive: Bool
        public let medianWithinOneSecond: Bool
        public let p90UnderThreeSeconds: Bool
        public var all: Bool {
            noUncorrectedClaims && noWrongfulAction95 && overallWithinFive && medianWithinOneSecond && p90UnderThreeSeconds
        }
    }

    public static let proposedMaxLossPoints = -5.0
    public static let proposedMedianSlackMs = 1000
    public static let proposedP90Ms = 3000
    public static let proposedNoWrongfulShare = 0.95

    public func bars(table: ComfortSummary, model: ComfortSummary) -> Bars {
        let noWrongful = model.noWrongfulTotal == 0 ? false
            : Double(model.noWrongfulPassed) / Double(model.noWrongfulTotal) >= Self.proposedNoWrongfulShare
        let median: Bool = {
            guard let m = model.comfortFirstAudioMedian, let t = table.comfortFirstAudioMedian else { return false }
            return m <= t + Self.proposedMedianSlackMs
        }()
        return Bars(noUncorrectedClaims: model.uncorrectedClaims == 0, noWrongfulAction95: noWrongful,
                    overallWithinFive: lowPoints >= Self.proposedMaxLossPoints, medianWithinOneSecond: median,
                    p90UnderThreeSeconds: (model.comfortFirstAudioP90 ?? Int.max) < Self.proposedP90Ms)
    }
}
