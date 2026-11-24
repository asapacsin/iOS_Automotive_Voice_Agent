import Foundation
import NovaKit

/// F-15b §50 item 9 (T-040v, owner 2026-11-19): one Qwen model per job. Code picks the route from the tool that runs,
/// never a router model. Every Qwen model name and option lives in this table; the clients hold none of their own.
///
/// F-18 §36 (T-046y, owner 2026-11-24, amends F-15b §50 item 10, §59 item 2, §62 item 7): each job has an ordered
/// list of models (`chain`), each entry with its own search options and thinking flag. A 429 or a quota 403 before any
/// answer moves the same request to the next entry (`QwenFallback`). §36 item 1: a model enters a list only after its
/// job's PC eval (row 35) passes; the spec's other entries wait in `awaitingEval` and are never called.
///
/// | Job | Chain (evaluated) | Awaiting row 35 | Search | Thinking | Budget |
/// |---|---|---|---|---|---|
/// | `live` | qwen3.7-flash → qwen3.8-flash | qwen3.8-max | turbo, forced, sources | off | as today |
/// | `ground` | qwen3.7-plus → qwen3.7-flash | qwen3.8-flash | turbo (row 160), forced, sources | off | 30 s |
/// | `picker` | qwen3.8-flash (§59) | qwen3.8-max, qwen3.8-max-0902 | off | off | 2.5 s |
/// | `planner` | qwen3.8-flash (§62) | qwen3.8-max, qwen3.8-max-0902 | off | off | 30 s |
/// | `eventsSearch` | qwen3.8-flash | qwen3.8-max | max, forced, sources | off | 45 s per query (§39) |
/// | `eventsExtract` | qwen3.8-flash | qwen3.8-max | off | off, not streamed, `json_object` (§39) | 30 s |
///
/// `planner` and `eventsExtract` use the OpenAI-compatible chat endpoint (`plannerEndpoint`); the others the native one.
public struct QwenRoute: Sendable, Hashable {
    public enum Job: String, Sendable, Hashable, CaseIterable {
        case live, picker, ground, planner
        case eventsExtract = "events_extract"
        case eventsSearch = "events_search"
    }

    public struct Search: Sendable, Hashable {
        public let strategy: String
        public let forced: Bool
        public let enableSource: Bool
    }

    /// One model of a job's list with its own options (§36 item 1).
    public struct Entry: Sendable, Hashable {
        public let model: String
        /// nil: search off (`enable_search=false`).
        public let search: Search?
        public let thinking: Bool

        public init(model: String, search: Search?, thinking: Bool) {
            self.model = model
            self.search = search
            self.thinking = thinking
        }
    }

    public let job: Job
    /// The ordered list; never empty. The route's own `model`/`search`/`thinking` are those of `entry`.
    public let chain: [Entry]
    /// The entry this route value sends (one of `chain`).
    public let entry: Entry
    /// §36 item 1: spec entries not yet listed because their row 35 eval has not passed. Never called.
    public let awaitingEval: [Entry]
    /// Streamed (`X-DashScope-SSE: enable`, `incremental_output`), read to the end before parsing.
    public let stream: Bool
    /// The route's time budget as the caller enforces it (picker `TripTuning.pickLimit`, ground
    /// `TripTuning.groundTimeout`; live: the executor's own, nil here). A later entry gets only what is left of it.
    public let budget: NovaDuration?

    public var model: String { entry.model }
    public var search: Search? { entry.search }
    public var thinking: Bool { entry.thinking }

    /// §50 item 10: after a 429 a model is skipped this long (Alibaba: limits usually recover within a minute).
    public static let cooldown = NovaDuration.seconds(60)
    /// §36 item 3: a quota 403 marks the model used up this long (or until the app restarts).
    public static let usedUpFor = NovaDuration.seconds(24 * 3600)

    public init(job: Job, chain: [Entry], awaitingEval: [Entry] = [], stream: Bool, budget: NovaDuration? = nil) {
        precondition(!chain.isEmpty, "a Qwen job needs at least one model")
        self.job = job
        self.chain = chain
        self.entry = chain[0]
        self.awaitingEval = awaitingEval
        self.stream = stream
        self.budget = budget
    }

    private init(_ route: QwenRoute, entry: Entry) {
        job = route.job
        chain = route.chain
        self.entry = entry
        awaitingEval = route.awaitingEval
        stream = route.stream
        budget = route.budget
    }

    /// The same route sending `entry` (one of `chain`).
    public func on(_ entry: Entry) -> QwenRoute { QwenRoute(self, entry: entry) }

    /// Model Studio, Singapore, multimodal API (the key's endpoint).
    public static let endpoint = "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

    private static let turbo = Search(strategy: "turbo", forced: true, enableSource: true)
    /// §36 PC check 2026-11-24: `qwen3.8-max` and `qwen3.8-flash` accept `max`, not `agent`.
    private static let maxSearch = Search(strategy: "max", forced: true, enableSource: true)

    /// F-18 §16 live info and §21 introductions (unchanged: §20 item 1, §22 item 1 chose `turbo`).
    public static let live = QwenRoute(job: .live,
                                       chain: [Entry(model: "qwen3.7-flash-2026-07-15", search: turbo, thinking: false),
                                               Entry(model: "qwen3.8-flash", search: turbo, thinking: false)],
                                       awaitingEval: [Entry(model: "qwen3.8-max", search: turbo, thinking: false)],
                                       stream: true)
    /// F-15b §4 item 6 picker: search off, not streamed. §59 (T-040zl, PC replay 2026-11-23): `qwen3.7-flash` answered
    /// "none" for all 22 names, `qwen3.8-flash` picked every one right.
    public static let picker = QwenRoute(job: .picker,
                                         chain: [Entry(model: "qwen3.8-flash", search: nil, thinking: false)],
                                         awaitingEval: [Entry(model: "qwen3.8-max", search: nil, thinking: false),
                                                        Entry(model: "qwen3.8-max-0902", search: nil, thinking: false)],
                                         stream: false, budget: .milliseconds(2500))
    /// F-15b §50 item 1: `forced_search` so the search must run (the answer's `search_info` is checked); plus is the
    /// "balanced" model. Row 160 (PC, 2026-11-19): `agent` and `max` answered with an empty `search_results`, so the
    /// search-ran check would refuse every answer; `turbo` returned 8 sources in 6.1 s. Hence `turbo`.
    public static let ground = QwenRoute(job: .ground,
                                         chain: [Entry(model: "qwen3.7-plus", search: turbo, thinking: false),
                                                 Entry(model: "qwen3.7-flash-2026-07-15", search: turbo, thinking: false)],
                                         awaitingEval: [Entry(model: "qwen3.8-flash", search: turbo, thinking: false)],
                                         stream: true, budget: .seconds(30))
    /// F-15b §62 item 10 (T-040zo): the trip planner on the compatible-mode chat endpoint, `json_object`, thinking off,
    /// 30 s (TripTuning.plannerTimeout). §36: its list is the same planner job on sibling models.
    public static let planner = QwenRoute(job: .planner,
                                          chain: [Entry(model: "qwen3.8-flash", search: nil, thinking: false)],
                                          awaitingEval: [Entry(model: "qwen3.8-max", search: nil, thinking: false),
                                                         Entry(model: "qwen3.8-max-0902", search: nil, thinking: false)],
                                          stream: false, budget: .seconds(30))
    /// F-18 §39 item 2 (T-046zb): one events keyword query, `max`, forced, sources; the answer text and the sources
    /// are kept. 45 s per query (`EventSearchRun.queryLimit`).
    public static let eventsSearch = QwenRoute(job: .eventsSearch,
                                               chain: [Entry(model: "qwen3.8-flash", search: maxSearch, thinking: false)],
                                               awaitingEval: [Entry(model: "qwen3.8-max", search: maxSearch, thinking: false)],
                                               stream: true, budget: .seconds(45))
    /// F-18 §39 item 3 (T-046zb): the one extraction call, compatible-mode chat, `json_object`, thinking off, 30 s.
    public static let eventsExtract = QwenRoute(job: .eventsExtract,
                                                chain: [Entry(model: "qwen3.8-flash", search: nil, thinking: false)],
                                                awaitingEval: [Entry(model: "qwen3.8-max", search: nil, thinking: false)],
                                                stream: false, budget: .seconds(30))

    public static let all: [QwenRoute] = [live, picker, ground, planner, eventsSearch, eventsExtract]

    /// F-15b §62 item 10 (T-040zo): the trip planner's first model (kept for callers that show it).
    public static var plannerModel: String { planner.model }
    /// Model Studio, Singapore, OpenAI-compatible chat completions; the same key as the routes above.
    public static let plannerEndpoint = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"

    public static func route(_ job: Job) -> QwenRoute {
        switch job {
        case .live: live
        case .picker: picker
        case .ground: ground
        case .planner: planner
        case .eventsSearch: eventsSearch
        case .eventsExtract: eventsExtract
        }
    }

    /// The route's `parameters`, with `extra` merged in (for example `response_format`). Sampling options stay the
    /// vendor's defaults (§50 item 9: nothing invented).
    public func parameters(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var p: [String: JSONValue] = [
            "result_format": "message",
            "enable_thinking": .bool(thinking),
            "enable_search": .bool(search != nil),
        ]
        if stream { p["incremental_output"] = true }
        if let search {
            p["search_options"] = ["search_strategy": .string(search.strategy), "enable_source": .bool(search.enableSource),
                                   "forced_search": .bool(search.forced)]
        }
        p.merge(extra) { _, new in new }
        return .object(p)
    }
}
