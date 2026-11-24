import Foundation
import NovaKit
import NovaNav
import NovaPorts
import NovaTools
import NovaVoice

/// F-09b §15 (T-031y): what shapes her behaviour, in a fixed order, with a version from
/// specs/contracts/agent-versions.md and a fingerprint computed from the texts actually sent.
/// Not in it: audio, UI, network and log code, keys (item 1).
public struct AgentSetup: Sendable, Hashable {
    /// Item 3: equals the newest row of specs/contracts/agent-versions.md.
    public static let version = "10.1.0"

    /// One session's settings that change what is sent (item 1). Comfort mode has one value ("model"); the language
    /// has no setting (F-05a: she follows the driver), so neither is a dimension.
    public struct Settings: Sendable, Hashable {
        public var style: SpeakingStyle
        public var webSearch: Bool
        public init(style: SpeakingStyle, webSearch: Bool) {
            self.style = style
            self.webSearch = webSearch
        }
        public var label: String { "\(style.rawValue).\(webSearch ? "search" : "nosearch")" }
        public static var all: [Settings] {
            SpeakingStyle.allCases.flatMap { s in [false, true].map { Settings(style: s, webSearch: $0) } }
        }
    }

    public struct Part: Sendable, Hashable {
        public let name: String
        public let text: String
    }

    public let parts: [Part]

    /// Item 1 for one session's settings, in order: model, base instruction as sent, tools, note templates, tuning.
    public init(_ settings: Settings, model: String = SessionConfig.defaultModel) {
        let tag = settings.label
        var parts = [Part(name: "model", text: model)]
        let instruction = PersonaInstruction.build(base: PersonaInstruction.base(PersonaInstruction.base, webSearch: settings.webSearch),
                                                   style: settings.style)
        parts.append(Part(name: "base.\(tag)", text: instruction))
        for tool in ToolCatalog.declarations(webSearch: settings.webSearch) {
            parts.append(Part(name: "tool.\(settings.webSearch ? "search" : "nosearch").\(tool.name).description", text: tool.description))
            parts.append(Part(name: "tool.\(settings.webSearch ? "search" : "nosearch").\(tool.name).schema",
                              text: Self.canonical(tool.parametersJSONSchema)))
        }
        for (name, text) in Self.noteTemplates { parts.append(Part(name: "note.\(name)", text: text)) }
        for (name, value) in Self.tuning { parts.append(Part(name: "tuning.\(name)", text: value)) }
        self.parts = parts
    }

    /// All settings combined (the test's `agentSetupHash`): every part once, by name.
    public static func combined() -> [Part] {
        var seen: Set<String> = []
        var out: [Part] = []
        for s in Settings.all {
            for p in AgentSetup(s).parts where seen.insert(p.name).inserted { out.append(p) }
        }
        return out
    }

    /// Item 2: SHA-256 over the parts as UTF-8, each `name`, a unit separator, the text, a record separator; first
    /// 12 hex characters.
    public static func hash(_ parts: [Part]) -> String {
        let joined = parts.map { $0.name + "\u{1F}" + $0.text + "\u{1E}" }.joined()
        return String(SHA256Digest.hex(joined).prefix(12))
    }

    /// The session's `agentHash`.
    public var hash: String { Self.hash(parts) }

    /// The setup's `agentSetupHash`.
    public static var setupHash: String { hash(combined()) }

    /// The `[系统]` note templates with their variable parts as placeholders (item 1).
    public static var noteTemplates: [(String, String)] {
        var out = CorrectionReason.allCases.map { ("correction.\($0.rawValue)", $0.instruction) }
        out.append(("correction.wrongLanguageHeard", CorrectionReason.wrongLanguage(heard: "<words>")))
        out.append(("summary", ExchangeMemory.summaryText(ExchangeMemory.summaryLine(driver: "<driver>", reply: "<reply>",
                                                                                       tools: ["<tool>", "<tool>"]))))
        out.append(("summaryNoTools", ExchangeMemory.summaryLine(driver: "<driver>", reply: "<reply>", tools: [])))
        // Both branches of every conditional part (review of T-031y): off/on, playing or not, speed known or not.
        out.append(("carState", CarStateSnapshot(acOn: false, temperatureC: 0, fanLevel: 0, windows: [:], driverSeat: 0,
                                                 musicPlaying: false, speedKmh: nil).note))
        out.append(("carStateOn", CarStateSnapshot(acOn: true, temperatureC: 0.5, fanLevel: 0, windows: [:], driverSeat: 0,
                                                   musicPlaying: true, speedKmh: 0).note))
        out.append(("destination", AgentState.destinationNote("<name>")))
        out.append(("destinationNone", AgentState.destinationNote(nil)))
        out.append(("screenPick", AgentState.screenPickNote(tool: "<tool>", index: AgentState.screenPickIndex("<index>"),
                                                            result: "<result>")))
        out.append(("now", ContextSnapshot(place: ContextPlace(city: "<city>", district: "<district>"), onHighway: true,
                                           localTime: "<time>").note))
        out.append(("nowOther", ContextSnapshot(place: nil, onHighway: false, localTime: "<time>").note))
        out.append(("nowTrip", ContextSnapshot(place: ContextPlace(city: nil, district: nil, trip: "<trip>"), onHighway: nil,
                                               localTime: "<time>").note))
        // F-09b §16 item 4 (T-031z): the 屏幕 line's text (all off, volume 0; only on/off and the number vary).
        out.append(("screen", ScreenState().line))
        out.append(("tripArrivedNext", TripPlanner.arrivedNextNote(index: "<n>", name: "<name>", next: "<next>",
                                                                   minutes: TripPlanner.minutesText("<minutes>"))))
        out.append(("tripArrivedHotel", TripPlanner.arrivedHotelNote(name: "<name>", nextDay: "<day>")))
        out.append(("tripArrivedDayDone", TripPlanner.arrivedDayDoneNote(index: "<n>", name: "<name>")))
        for (name, what) in [("Opened", TripPlanner.editOpened("<name>")), ("Removed", TripPlanner.editRemoved("<n>", "<name>")),
                             ("Moved", TripPlanner.editMoved("<from>", "<to>")),
                             ("Added", TripPlanner.editAdded("<name>"))] {
            out.append(("tripScreenEdit\(name)", TripPlanner.screenEditNote(what: what, count: "<count>")))
        }
        // F-15b §57 item 5 (T-040zj): the navigation button taps (replace the 去下一站 screen-edit note).
        out.append(("navTapNext", TripPlanner.nextTapLine))
        out.append(("navTapStop", NavigationController.stopTapLine))
        return out
    }

    /// Item 1: `Tuning` values she acts on, marked `// agentSetup` in Tuning.swift (a test keeps the two equal).
    /// None is marked yet (§14E's offer values are not built).
    public static let tuning: [(String, String)] = []

    /// Item 6: the record header lines after `app`.
    public func headerLines(model: String = SessionConfig.defaultModel) -> [String] {
        ["agentVersion \(Self.version)", "agentHash \(hash)", "model \(model)"]
    }

    /// Item 6: the session-start log line (no text, I-8).
    public func logLine(model: String = SessionConfig.defaultModel) -> String {
        "agent version=\(Self.version) hash=\(hash) model=\(model)"
    }

    static func canonical(_ v: JSONValue) -> String {
        (try? JSONValue.canonicalEncoder().encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
