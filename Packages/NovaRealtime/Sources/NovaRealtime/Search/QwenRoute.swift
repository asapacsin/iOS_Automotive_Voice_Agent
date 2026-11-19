import Foundation
import NovaKit

/// F-15b §50 item 9 (T-040v, owner 2026-11-19): one Qwen model per job. Code picks the route from the tool that runs,
/// never a router model. Every Qwen model name and option lives in this table; the clients hold none of their own.
///
/// | Route | Model | Search | Thinking | Budget | Backup (§50 item 10, T-040x) |
/// |---|---|---|---|---|---|
/// | `live` | qwen3.7-flash | turbo, forced, sources | off | as today | qwen3.8-flash |
/// | `picker` | qwen3.7-flash | off | off | 2.5 s (TripTuning.pickLimit) | qwen3.8-flash |
/// | `ground` | qwen3.7-plus | agent, forced, sources | off | 30 s (TripTuning.groundTimeout) | qwen3.7-flash + turbo |
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
    /// §50 item 10 hook (T-040x, not implemented here): the model and search options of the backup route used only
    /// on an HTTP 429 or a quota 403 before any answer arrives. Nothing reads it yet.
    public let backupModel: String
    public let backupSearch: Search?

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
                                         backupModel: "qwen3.8-flash", backupSearch: nil)
    /// F-15b §50 item 1: `agent` is Model Studio's multi-round search; `forced_search` so the search must run (the
    /// answer's `search_info` is checked); plus is the "balanced" model.
    public static let ground = QwenRoute(job: .ground, model: "qwen3.7-plus",
                                         search: Search(strategy: "agent", forced: true, enableSource: true),
                                         thinking: false, stream: true,
                                         backupModel: "qwen3.7-flash",
                                         backupSearch: Search(strategy: "turbo", forced: true, enableSource: true))

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
