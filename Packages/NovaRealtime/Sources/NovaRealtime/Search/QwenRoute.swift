import Foundation
import NovaKit

/// F-15b §50 item 9 (T-040v, owner 2026-11-19): one Qwen model per job. Code picks the route from the tool that runs,
/// never a router model. Every Qwen model name and option lives in this table; the clients hold none of their own.
///
/// | Route | Model | Search | Thinking | Budget | Backup (§50 item 10, T-040x) |
/// |---|---|---|---|---|---|
/// | `live` | qwen3.7-flash | turbo, forced, sources | off | as today | qwen3.8-flash |
/// | `picker` | qwen3.7-flash | off | off | 2.5 s (TripTuning.pickLimit) | qwen3.8-flash |
/// | `ground` | qwen3.7-plus | turbo (row 160), forced, sources | off | 30 s (TripTuning.groundTimeout) | qwen3.7-flash + turbo |
public struct QwenRoute: Sendable, Hashable {
    public enum Job: String, Sendable, Hashable, CaseIterable {
        case live, picker, ground
    }

    public struct Search: Sendable, Hashable {
        public let strategy: String
        public let forced: Bool
        public let enableSource: Bool
    }

    public let job: Job
    public let model: String
    /// nil: search off (`enable_search=false`).
    public let search: Search?
    public let thinking: Bool
    /// Streamed (`X-DashScope-SSE: enable`, `incremental_output`), read to the end before parsing.
    public let stream: Bool
    /// §50 item 10 (T-040x, `QwenFallback`): the model and search options of the backup route, used only on an HTTP
    /// 429 or a quota 403 before any answer arrives.
    public let backupModel: String
    public let backupSearch: Search?
    /// The route's time budget as the caller enforces it (picker `TripTuning.pickLimit`, ground
    /// `TripTuning.groundTimeout`; live: the executor's own, nil here). A backup call gets only what is left of it.
    public let budget: NovaDuration?

    /// §50 item 10: after a 429 the primary is skipped this long (Alibaba: limits usually recover within a minute).
    public static let cooldown = NovaDuration.seconds(60)

    public init(job: Job, model: String, search: Search?, thinking: Bool, stream: Bool, backupModel: String,
                backupSearch: Search?, budget: NovaDuration? = nil) {
        self.job = job
        self.model = model
        self.search = search
        self.thinking = thinking
        self.stream = stream
        self.backupModel = backupModel
        self.backupSearch = backupSearch
        self.budget = budget
    }

    /// The same route on its backup model and search options.
    public var backup: QwenRoute {
        QwenRoute(job: job, model: backupModel, search: backupSearch, thinking: thinking, stream: stream,
                  backupModel: backupModel, backupSearch: backupSearch, budget: budget)
    }

    /// Model Studio, Singapore, multimodal API (the key's endpoint).
    public static let endpoint = "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

    /// F-18 §16 live info and §21 introductions (unchanged: §20 item 1, §22 item 1 chose `turbo`).
    public static let live = QwenRoute(job: .live, model: "qwen3.7-flash",
                                       search: Search(strategy: "turbo", forced: true, enableSource: true),
                                       thinking: false, stream: true,
                                       backupModel: "qwen3.8-flash",
                                       backupSearch: Search(strategy: "turbo", forced: true, enableSource: true))
    /// F-15b §4 item 6 picker (unchanged): search off, not streamed.
    public static let picker = QwenRoute(job: .picker, model: "qwen3.7-flash", search: nil, thinking: false, stream: false,
                                         backupModel: "qwen3.8-flash", backupSearch: nil,
                                         budget: .milliseconds(2500))
    /// F-15b §50 item 1: `forced_search` so the search must run (the answer's `search_info` is checked); plus is the
    /// "balanced" model. Row 160 (PC, 2026-11-19): `agent` and `max` answered with an empty `search_results`, so the
    /// search-ran check would refuse every answer; `turbo` returned 8 sources in 6.1 s. Hence `turbo`.
    public static let ground = QwenRoute(job: .ground, model: "qwen3.7-plus",
                                         search: Search(strategy: "turbo", forced: true, enableSource: true),
                                         thinking: false, stream: true,
                                         backupModel: "qwen3.7-flash",
                                         backupSearch: Search(strategy: "turbo", forced: true, enableSource: true),
                                         budget: .seconds(30))

    public static let all: [QwenRoute] = [live, picker, ground]

    public static func route(_ job: Job) -> QwenRoute {
        switch job {
        case .live: live
        case .picker: picker
        case .ground: ground
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
