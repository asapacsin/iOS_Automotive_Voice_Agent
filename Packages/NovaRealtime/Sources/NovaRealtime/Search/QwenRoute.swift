import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit

/// F-15b §50 item 9 (T-040v, owner 2026-11-19): one Qwen model per job. Code picks the route from the tool that runs,
/// never a router model. Every Qwen model name and option lives in this table; the clients hold none of their own.
///
/// F-18 §36 (T-046y, owner 2026-11-24, amends F-15b §50 item 10, §59 item 2, §62 item 7): each job has an ordered
/// list of models (`chain`), each entry with its own search options and thinking flag. A 429 or a quota 403 before any
/// answer moves the same request to the next entry (`QwenFallback`). §36 item 1: a model enters a list only after its
/// job's PC eval (row 35) passes (superseded by F-18 §40: the five Beijing models, `awaitingEval` empty).
///
/// F-18 §40 (T-046zc, owner order 2026-11-25): every job runs on the Beijing 百炼 account's free-quota models only,
/// earliest free-quota expiry first (`qwen3.8-max-0902` 12-01, `deepseek-v4.1-flash` 12-13, `deepseek-v4.1-flash-1017`
/// 01-17, `kimi-k3.1-pro` 02-02, `qwen4-max` 02-14). `awaitingEval` is empty. A used-up free quota answers 403
/// `AllocationQuota.FreeTierOnly`, which `QwenFallback` treats as quota.
///
/// | Job | Chain | Search | Thinking | Budget |
/// |---|---|---|---|---|
/// | `live` | `searchChain` | Responses `web_search` (§41) | off, not streamed | as today |
/// | `ground` | `searchChain` | Responses `web_search` (§41) | off, not streamed | 30 s |
/// | `eventsSearch` | `searchChain` | Responses `web_search` (§41) | off, not streamed | 45 s per query (§39) |
/// | `picker` | `textChain` | off | off | 2.5 s |
/// | `planner` | `textChain` | off | off | 30 s |
/// | `eventsExtract` | `textChain` | off | off, not streamed, `json_object` (§39) | 30 s |
///
/// `searchChain`: deepseek-v4.1-flash → deepseek-v4.1-flash-1017 → qwen4-max (kimi-k3.1-pro cannot search;
/// qwen3.8-max-0902 gave no search answer in 240 s). `textChain`: qwen3.8-max-0902 → deepseek-v4.1-flash →
/// deepseek-v4.1-flash-1017 → kimi-k3.1-pro → qwen4-max.
///
/// `planner` and `eventsExtract` use the OpenAI-compatible chat endpoint (`plannerEndpoint`); `picker` the native one.
///
/// F-18 §41 (T-046zd, owner order 2026-11-25): `enable_search` returns no pages on the Beijing key, so the search jobs
/// (`live`, `ground`, `eventsSearch`) send to the Responses API (`responsesEndpoint`) with the `web_search` tool, thinking
/// off, not streamed (`responsesBody`). No `enable_search`, `search_options` or `web_extractor`.
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

    /// F-18 §40 item 1: Model Studio, Beijing, multimodal API (the 设置 「千问 key」 is the Beijing account's).
    public static let endpoint = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

    private static let turbo = Search(strategy: "turbo", forced: true, enableSource: true)
    private static let maxSearch = Search(strategy: "max", forced: true, enableSource: true)

    /// F-18 §40 item 3: the only five models any job may call; F-18 §46 item 1 (T-046zi, owner 2026-11-26) adds
    /// `qwen3.5-omni-flash` (poster reading, venue and hour, `QwenOmniReader`).
    public static let allowedModels: Set<String> = ["qwen3.8-max-0902", "deepseek-v4.1-flash", "deepseek-v4.1-flash-1017",
                                                    "kimi-k3.1-pro", "qwen4-max", "qwen3.5-omni-flash"]
    /// F-18 §46 item 1: the poster and venue/hour reader (`QwenOmniReader`), streamed, text out.
    public static let omniModel = "qwen3.5-omni-flash"
    /// §40 item 2: the search jobs' list.
    static let searchModels = ["deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "qwen4-max"]
    /// §40 item 2: the jobs without search.
    static let textModels = ["qwen3.8-max-0902", "deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "kimi-k3.1-pro", "qwen4-max"]

    private static func chain(_ models: [String], search: Search?) -> [Entry] {
        models.map { Entry(model: $0, search: search, thinking: false) }
    }

    /// F-18 §16 live info and §21 introductions.
    public static let live = QwenRoute(job: .live, chain: chain(searchModels, search: turbo), stream: false)
    /// F-15b §4 item 6 picker: search off, not streamed, 2.5 s (§40 item 6: watch `pick … ms=` on the phone).
    public static let picker = QwenRoute(job: .picker, chain: chain(textModels, search: nil), stream: false,
                                         budget: .milliseconds(2500))
    /// F-15b §50 item 1: `forced_search` so the search must run; `turbo` (row 160).
    public static let ground = QwenRoute(job: .ground, chain: chain(searchModels, search: turbo), stream: false, budget: .seconds(30))
    /// F-15b §62 item 10 (T-040zo): the trip planner on the compatible-mode chat endpoint, `json_object`, 30 s.
    public static let planner = QwenRoute(job: .planner, chain: chain(textModels, search: nil), stream: false, budget: .seconds(30))
    /// F-18 §39 item 2 (T-046zb): one events keyword query, `max`, forced, sources; 45 s per query.
    public static let eventsSearch = QwenRoute(job: .eventsSearch, chain: chain(searchModels, search: maxSearch), stream: false,
                                               budget: .seconds(45))
    /// F-18 §39 item 3 (T-046zb): the one extraction call, compatible-mode chat, `json_object`, 30 s.
    public static let eventsExtract = QwenRoute(job: .eventsExtract, chain: chain(textModels, search: nil), stream: false,
                                                budget: .seconds(30))

    public static let all: [QwenRoute] = [live, picker, ground, planner, eventsSearch, eventsExtract]

    /// F-15b §62 item 10 (T-040zo): the trip planner's first model (kept for callers that show it).
    public static var plannerModel: String { planner.model }
    /// F-18 §40 item 1: Model Studio, Beijing, OpenAI-compatible chat completions; the same key as the routes above.
    public static let plannerEndpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

    /// F-18 §41 item 1: the Responses API, Beijing; the search jobs send here.
    public static let responsesEndpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/responses"

    /// §41 item 1: the route sends a search (the Responses `web_search` tool) instead of a plain call.
    public var usesResponses: Bool { search != nil }

    /// §41 item 2: `{"model", "input": [{"role","content": text}], "tools": [{"type":"web_search"}], "enable_thinking": false}`,
    /// not streamed. The messages are the client's own, unchanged (owner rule 2026-11-05).
    public func responsesBody(_ messages: [(role: String, text: String)]) -> JSONValue {
        [
            "model": .string(model),
            "input": .array(messages.map { ["role": .string($0.role), "content": .string($0.text)] }),
            "tools": [["type": "web_search"]],
            "enable_thinking": .bool(thinking),
        ]
    }

    /// §41: a `POST` to `responsesEndpoint` with `responsesBody`, the key in the `Authorization` header only.
    public func responsesRequest(_ messages: [(role: String, text: String)], key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.responsesEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONValue.canonicalEncoder().encode(responsesBody(messages))
        return request
    }

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
