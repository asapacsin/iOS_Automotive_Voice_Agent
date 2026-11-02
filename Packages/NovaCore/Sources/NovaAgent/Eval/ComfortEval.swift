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

/// One run of one case.
public struct ComfortRun: Sendable, Hashable {
    public let caseID: String
    public let attempt: Int
    public let end: ComfortVehicleState
    public let calls: [ComfortCallRecord]
    /// The reply text: shown on screen for reading, never logged (I-8).
    public let reply: String
    /// From sending the sentence to the first reply audio.
    public let firstAudioMs: Int?
    public let timedOut: Bool

    public init(caseID: String, attempt: Int, end: ComfortVehicleState, calls: [ComfortCallRecord], reply: String,
                firstAudioMs: Int?, timedOut: Bool) {
        self.caseID = caseID
        self.attempt = attempt
        self.end = end
        self.calls = calls
        self.reply = reply
        self.firstAudioMs = firstAudioMs
        self.timedOut = timedOut
    }
}

public enum ComfortFailure: Sendable, Hashable {
    case timedOut
    case wrongDecision(ComfortDecision)
    case missingChange
    case forbiddenChange(ComfortFacet)
    case windowAboveLimit
    case noMention
    case unbackedClaim

    /// Numbers and enums only (I-8).
    public var code: String {
        switch self {
        case .timedOut: "timedOut"
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
        if run.timedOut { return fail(.timedOut) }
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

/// Item 5: the report the owner screenshots. `logLine` holds numbers and case ids only (I-8).
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
        /// For reading on screen only.
        public let reply: String
    }

    public var overall = Tally()
    public var byDecision: [ComfortDecision: Tally] = [:]
    public var tuning = Tally()
    public var heldOut = Tally()
    public var unprompted = Tally()
    /// `noTool` and `refuse` cases that ended with no wrongful action (item 14).
    public var noWrongfulAction = Tally()
    public var failures: [Failure] = []
    public var medianFirstAudioMs: Int?
    public var worstFirstAudioMs: Int?
    public var callsPerRun = 0.0
    public var blocked = 0
    public var unbackedClaims = 0

    public init(cases: [ComfortCase], runs: [ComfortRun]) {
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        var times: [Int] = []
        var calls = 0
        for run in runs {
            guard let c = byID[run.caseID] else { continue }
            let score = ComfortScorer.score(c, run)
            func add(_ t: inout Tally) { t.total += 1; if score.pass { t.passed += 1 } }
            add(&overall)
            add(&byDecision[c.expected, default: Tally()])
            if c.heldOut { add(&heldOut) } else { add(&tuning) }
            if c.unprompted { add(&unprompted) }
            if c.expected == .noTool || c.expected == .refuse {
                noWrongfulAction.total += 1
                if !(score.decision == .act && !c.accepted.contains(.act)) { noWrongfulAction.passed += 1 }
            }
            if let failure = score.failure {
                failures.append(Failure(caseID: c.id, attempt: run.attempt, reason: failure, reply: run.reply))
            }
            if ComfortScorer.unbackedClaim(run) { unbackedClaims += 1 }
            if let t = run.firstAudioMs { times.append(t) }
            calls += run.calls.count
            blocked += run.calls.filter { $0.code == .vehicleBlocked }.count
        }
        times.sort()
        medianFirstAudioMs = times.isEmpty ? nil : times[times.count / 2]
        worstFirstAudioMs = times.last
        callsPerRun = runs.isEmpty ? 0 : Double(calls) / Double(runs.count)
    }

    /// `comfortEval mode overall=.. heldOut=.. ...` plus the failing case ids; never reply text.
    public func logLine(mode: ToolCatalog.ComfortMode) -> String {
        var parts = ["comfortEval mode=\(mode.rawValue)",
                     "overall=\(overall.passed)/\(overall.total)", "tuning=\(tuning.passed)/\(tuning.total)",
                     "heldOut=\(heldOut.passed)/\(heldOut.total)", "unprompted=\(unprompted.passed)/\(unprompted.total)",
                     "noWrongfulAction=\(noWrongfulAction.passed)/\(noWrongfulAction.total)"]
        for d in ComfortDecision.allCases {
            let t = byDecision[d] ?? Tally()
            parts.append("\(d.rawValue)=\(t.passed)/\(t.total)")
        }
        parts += ["medianMs=\(medianFirstAudioMs.map(String.init) ?? "none")",
                  "worstMs=\(worstFirstAudioMs.map(String.init) ?? "none")",
                  "callsPerRun=\(String(format: "%.2f", callsPerRun))", "blocked=\(blocked)", "unbacked=\(unbackedClaims)",
                  "failed=" + failures.map { "\($0.caseID)#\($0.attempt):\($0.reason.code)" }.joined(separator: ",")]
        return parts.joined(separator: " ")
    }
}
