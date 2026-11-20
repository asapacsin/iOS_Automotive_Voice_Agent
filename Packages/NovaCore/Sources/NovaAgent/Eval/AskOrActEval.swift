import NovaKit
import NovaPorts

/// F-09b §14 item 5 (T-031p): the ask-or-act eval and the complaint set. Multi-turn cases with scripted driver
/// replies, scored by behaviour, never by wording: a tool called or not, the right tool, nothing done before
/// agreement where the driver had not decided, a question only where the driver had not decided, claims matching
/// results. Run on the PC against the live model with the app's real instruction, notes and tools (10 runs per
/// case); this file holds the cases and the scoring only (no network, no key).
/// Stage pass: `AskOrActEval` ≥ 9 of 10 per case; the complaint set has no new failure against the baseline.
public enum AskOrActEval {
    public enum Group: String, Sendable, Hashable, CaseIterable { case askOrAct, complaint }

    /// Tools that only read: allowed in a turn where the driver has not decided.
    public static let readOnly: Set<String> = ["get_vehicle_state", "query_live_info", "web_search",
                                                     "google_search", "trip_plans"]

    /// What one driver turn expects of her.
    public enum Expect: Sendable, Hashable {
        /// The driver has decided: one of `tools` is called (any acting tool when empty), and no question.
        case act(Set<String>)
        /// Not decided: nothing done (read-only tools only), and a question (a suggestion with a reason, asked).
        case offer
        /// Answer only: no acting tool and no question (「不用」, 「为什么开车容易犯困」, 「现在几点」).
        case answer
        /// 「随便」: she goes with her own suggestion; no question, acting allowed.
        case goes
    }

    public struct Turn: Sendable, Hashable {
        public let said: String
        public let expect: Expect
        public init(_ said: String, _ expect: Expect) {
            self.said = said
            self.expect = expect
        }
    }

    public struct Case: Sendable, Hashable, Identifiable {
        public let id: String
        public let group: Group
        /// Earlier turns (a recommendation, a change, a list) the case starts from.
        public let history: [TextTurn]
        public let turns: [Turn]
        public init(_ id: String, _ group: Group, history: [TextTurn] = [], _ turns: [Turn]) {
            self.id = id
            self.group = group
            self.history = history
            self.turns = turns
        }
    }

    /// One of her turns in a run: the tools she called and whether her reply asked (the runner decides by the
    /// reply's last sentence ending in a question), and whether every claim matched a tool result.
    public struct TurnRun: Sendable, Hashable {
        public let tools: [String]
        public let asked: Bool
        public let claimsMatch: Bool
        public init(tools: [String], asked: Bool, claimsMatch: Bool = true) {
            self.tools = tools
            self.asked = asked
            self.claimsMatch = claimsMatch
        }
    }

    /// Why a turn failed. Behaviour only.
    public enum Failure: String, Sendable, Hashable, CaseIterable {
        case noTool, wrongTool, actedBeforeAgreement, askedWhenDecided, noQuestion, claimMismatch
    }

    public static func score(_ turn: Turn, _ run: TurnRun) -> Failure? {
        if !run.claimsMatch { return .claimMismatch }
        let acting = run.tools.filter { !readOnly.contains($0) }
        switch turn.expect {
        case .act(let tools):
            let called = tools.isEmpty ? acting : run.tools.filter { tools.contains($0) }
            if called.isEmpty { return run.tools.isEmpty ? .noTool : .wrongTool }
            if run.asked { return .askedWhenDecided }
        case .offer:
            if !acting.isEmpty { return .actedBeforeAgreement }
            if !run.asked { return .noQuestion }
        case .answer:
            if !acting.isEmpty { return .actedBeforeAgreement }
            if run.asked { return .askedWhenDecided }
        case .goes:
            if run.asked { return .askedWhenDecided }
        }
        return nil
    }

    /// A run of a case passes when every turn passes; the first failure is kept. A run shorter than the case
    /// (her session ended) fails at the first missing turn with `noTool`.
    public static func score(_ c: Case, _ runs: [TurnRun]) -> (turn: Int, failure: Failure)? {
        for (i, turn) in c.turns.enumerated() {
            guard i < runs.count else { return (i, .noTool) }
            if let f = score(turn, runs[i]) { return (i, f) }
        }
        return nil
    }

    public struct Report: Sendable, Hashable {
        public let caseID: String
        public let runs: Int
        public let passed: Int
        public let failures: [Failure: Int]
        /// ≥ 9 of 10 (item 5).
        public var pass: Bool { runs > 0 && passed * 10 >= runs * 9 }
        /// `ask-or-act case=<id> runs= passed= pass=` and the failure counts (numbers and ids only, I-8).
        public var logLine: String {
            let f = Failure.allCases.compactMap { k in failures[k].map { "\(k.rawValue)=\($0)" } }.joined(separator: " ")
            return "ask-or-act case=\(caseID) runs=\(runs) passed=\(passed) pass=\(pass ? "yes" : "no")" + (f.isEmpty ? "" : " " + f)
        }
    }

    public static func report(_ c: Case, _ runs: [[TurnRun]]) -> Report {
        var failures: [Failure: Int] = [:]
        var passed = 0
        for run in runs {
            if let f = score(c, run) { failures[f.failure, default: 0] += 1 } else { passed += 1 }
        }
        return Report(caseID: c.id, runs: runs.count, passed: passed, failures: failures)
    }

    /// The complaint set's stage gate: no case that passed at the baseline fails now.
    public static func newFailures(baseline: [Report], now: [Report]) -> [String] {
        let before = Dictionary(uniqueKeysWithValues: baseline.map { ($0.caseID, $0.pass) })
        return now.filter { !$0.pass && before[$0.caseID] == true }.map(\.caseID)
    }

    // MARK: Cases

    private static func driver(_ text: String) -> TextTurn { TextTurn(role: .user, text: text) }
    private static func her(_ text: String) -> TextTurn { TextTurn(role: .model, text: text) }

    /// Item 5's `AskOrActEval`.
    public static let askOrAct: [Case] = [
        Case("sleepy-yes", .askOrAct, [Turn("有點困了", .offer), Turn("好", .act(["navigate_to"]))]),
        Case("sleepy-no", .askOrAct, [Turn("有點困了", .offer), Turn("不用", .answer)]),
        Case("family-3days", .askOrAct, [Turn("想带家人玩三天，不知道去哪", .offer), Turn("太近了", .offer),
                                         Turn("好", .act(["make_trip_list"]))]),
        Case("weekend-any", .askOrAct, [Turn("周末带孩子去哪玩", .offer), Turn("随便", .goes)]),
    ]

    /// Item 5's complaint set: every phrase an earlier rule was written for, with what the driver expected then.
    public static let complaint: [Case] = [
        Case("hot", .complaint, [Turn("有点热", .act(["control_climate"]))]),
        Case("guangdong-3days", .complaint, [Turn("准备一个广东三天的旅游行程", .act(["make_trip_list"]))]),
        Case("checklist-after-tip", .complaint,
             history: [driver("天津有什么好玩的"), her("天津可以去五大道、古文化街、天津之眼和瓷房子。")],
             [Turn("做个打卡清单", .act(["make_trip_list"]))]),
        Case("lower-again", .complaint,
             history: [driver("温度调低一点"), her("已经调到23度了。")],
             [Turn("再低一点", .act(["control_climate"]))]),
        Case("where-am-i", .complaint, [Turn("我现在在哪", .act(["query_live_info"]))]),
        Case("what-time", .complaint, [Turn("现在几点", .answer)]),
        Case("nav-zhuhai-station", .complaint, [Turn("导航去珠海站", .act(["navigate_to"]))]),
        Case("second-one", .complaint,
             history: [driver("附近的加油站"), her("找到三个：中石化拱北站、中石油前山站、壳牌香洲站。去哪个？")],
             [Turn("第二个", .act(["choose_navigation_option"]))]),
        Case("why-sleepy", .complaint, [Turn("为什么开车容易犯困", .answer)]),
        Case("nav-office", .complaint, [Turn("导航去公司", .act(["navigate_to"]))]),
    ]

    public static var cases: [Case] { askOrAct + complaint }
}
