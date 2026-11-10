import Foundation
import NovaKit
import NovaNav
import NovaPorts
import NovaTools
import NovaVoice
import Synchronization

/// F-12 §17 (T-031f): one thing that happened in a conversation, as the test record sees it. Off by default; the
/// record is a local file, never a log (I-8, product-spec I-7/I-8 note). Pure.
public enum RecordEvent: Sendable, Hashable {
    /// The bundled recognizer's final words; nil = （没听清）. F-05a §14 item 5: `language` set means SenseVoice
    /// gave the final (`asr=sensevoice lang=<…>`); nil is the streaming model (`asr=stream lang=stream`).
    case heardLocal(String?, language: SpokenLanguage? = nil)
    /// F-05a §14 item 5: the multilingual model's state changed (`asr-model state=<…>`).
    case asrModel(MultilingualModelState)
    case heardGemini(String)
    case utterance(id: Int, sent: Bool, mute: String)
    case turnStarted(TurnID)
    case replyText(TurnID, String)
    /// A judged clause went to her voice.
    case spoke
    /// The claim gate held events before they were released.
    case held
    /// Her playback was flushed (a void or a barge-in).
    case flushed
    case toolCall(name: String, arguments: JSONValue)
    /// `elapsedMs` set: a background tool's result (F-18 §27 item 6), logged with its scheduling and time.
    case toolResult(name: String, ok: Bool, code: String?, data: JSONValue, elapsedMs: Int? = nil)
    /// F-18 §27 item 4: a background tool's result dropped because the socket was replaced.
    case toolDropped(AsyncTool)
    case correction(String)
    case playbackStarted
    case playbackFinished
    case bargeIn(stopped: Bool)
    case generationComplete(TurnID)
    case turnComplete(TurnID, outcome: String)
    case turnEnded(TurnEndReason)
    /// F-18 §16 item 12: `search <queries the search model ran>`.
    case search(String?)
    case session(String)
    /// F-18 §18 items 1-2, 5 (T-046f): one request to the search model and its reply.
    case searchExchange(WebSearchExchange)
    /// F-18 §18 item 3, §19 item 6, §21 item 7: what a `web_search` call did (`used`, `failed`, `date`, `place`).
    case searchOutcome(WebSearchOutcome)
    /// F-18 §21 item 7: a destination note; nil = the end note.
    case contextNote(destination: String?)
    /// F-05a §13 item 5: text the screen check hid; the first 80 characters.
    case screenHidden(kind: ScreenTextKind, text: String)
    /// F-01 §14 item 12 (T-060a): a woken session first reached listening `ms` after the wake.
    case wakeToListening(ms: Int)
    /// F-01 §14 item 12: a woken session ended with no utterance sent (a false wake).
    case wakeUnused
    /// F-24 §15 item 8 (T-016j): `session gave-up ms= attempts= code=`; numbers and a code, never the handle.
    case sessionGaveUp(ms: Int, attempts: Int, code: RetryableErrorCode)
    /// F-24 §15 item 8: `session resume handle=yes|no result=resumed|rejected|none`, in the next session's record.
    case sessionResume(handle: Bool, result: SessionResumeResult)
    /// F-04b §7 (T-013e): `speaker-check utterance= kind= score= threshold= result= speechMs= scoreMs= waitMs=`.
    case speakerCheck(SpeakerCheckLine)
    /// F-16 §14 item 9 (T-042c): `dest-search destination= step= n= top= score= km= check=`.
    case destSearch(DestinationSearchLine)
    /// F-07 §14 item 8 (T-020a): `voice source= chars= first_ms= ms= attempt=`.
    case voiceClause(VoiceClauseLine)
    /// F-07 §14 item 7: `voice-failed turn= source= code=`.
    case voiceFailed(VoiceFailedLine)
    /// F-07 §15 item 5 (T-020b): `voice source=gemini turn= held_ms= first_ms=`.
    case voiceGemini(GeminiVoiceLine)
    /// F-24 §16 item 3 (T-020b): `session closed code= reason=`.
    case sessionClosed(SessionClosedLine)
    /// F-07 §15 item 8 (T-020b): `claim-cut turn= played_ms=`.
    case claimCut(turn: Int, playedMs: Int)
    /// F-13 §17 item 6 (T-032e): a `music …` line (search, preview start/playing/failed/cut/ended); numbers and codes.
    case music(String)
    /// F-05a §15 item 7 (T-016m): `lang-check …`, `correction WRONG_LANGUAGE heard=…`, `fallback-line …`.
    case languageLine(ReplyLanguageLine)
}

/// Header facts (§17 item 3). Never a key or the system instruction: there is no field for them.
public struct RecordHeader: Sendable, Hashable {
    public let appVersion: String
    public let comfortMode: String
    public let interruptible: Bool
    public let speakingStyle: String
    /// F-18 §16 item 12: which information path ran.
    public let webSearch: Bool
    /// F-18 §18 item 6: whether a search key is saved; nil writes no line. Never the key's value.
    public let searchKey: Bool?
    /// F-01 §14 item 12 (T-060a): `wake` or `tap`; nil writes no line.
    public let startedBy: String?

    public init(appVersion: String, comfortMode: String, interruptible: Bool, speakingStyle: String, webSearch: Bool = false,
                searchKey: Bool? = nil, startedBy: String? = nil) {
        self.startedBy = startedBy
        self.webSearch = webSearch
        self.searchKey = searchKey
        self.appVersion = appVersion
        self.comfortMode = comfortMode
        self.interruptible = interruptible
        self.speakingStyle = speakingStyle
    }

    public var lines: [String] {
        ["app \(appVersion)", "comfortMode \(comfortMode)", "可以打断她 \(interruptible ? "on" : "off")",
         "speakingStyle \(speakingStyle)", "webSearch \(webSearch ? "on" : "off")"]
            + (searchKey.map { ["searchKey \($0 ? "saved" : "missing")"] } ?? [])
            + (startedBy.map { ["startedBy \($0)"] } ?? [])
    }
}

/// Turns events into lines (§17 item 4): `<ms> <kind> <content>`. Reply pieces are merged into one `reply` line per
/// turn, written when the turn ends, with the time of its first piece. The core judges a turn after the provider ends
/// it (a whole-held reply is released, or a claim voided, at `responseDone` or later), so `reply-out` is written only
/// at the next correction, turn, driver words or session event; marks that arrive after `responseDone` still count.
/// A clause spoken only after the turn ended means it was held whole. A void takes the reason of the correction
/// that follows it, else `none`.
public struct ConversationRecorder: Sendable {
    private struct Turn: Sendable {
        let id: TurnID
        var firstMs: Int64
        var text = ""
        var spoke = false
        var spokeAfterEnd = false
        var held = false
        var flushed = false
        var bargedIn = false
        var ended = false
    }

    /// Open turns, and the last ended one waiting for its `reply-out`.
    private var open: [TurnID: Turn] = [:]
    private var current: TurnID?
    private var awaiting: Turn?

    public init() {}

    public mutating func add(_ event: RecordEvent, atMs ms: Int64) -> [String] {
        func line(_ kind: String, _ content: String) -> String { "\(ms) \(kind) \(content)" }
        switch event {
        case .heardLocal(let words, let language):
            let tags = language.map { " lang=\($0.rawValue) asr=sensevoice" } ?? " lang=stream asr=stream"
            return settle(ms, reason: nil) + [line("heard-local", (words ?? "（没听清）") + tags)]
        case .asrModel(let state): return [line("asr-model", "state=\(state.code)")]
        case .heardGemini(let text): return [line("heard-gemini", text)]
        case .utterance(let id, let sent, let mute): return [line("utterance", "id=\(id) sent=\(sent) mute=\(mute)")]
        case .turnStarted(let t):
            let out = settle(ms, reason: nil)
            begin(t, ms)
            return out
        case .replyText(let t, let text):
            var out: [String] = []
            if open[t] == nil { out = settle(ms, reason: nil); begin(t, ms) }
            open[t]?.text += text
            return out
        case .spoke: mark { $0.spoke = true; if $0.ended { $0.spokeAfterEnd = true } }; return []
        case .held: mark { $0.held = true }; return []
        case .flushed: mark { $0.flushed = true }; return []
        case .bargeIn(let stopped):
            if stopped { mark { $0.bargedIn = true } }
            return [line("barge-in", stopped ? "stopped" : "rejected")]
        case .toolCall(let name, let args):
            // F-18 §27 item 6: a NON_BLOCKING call is marked.
            let async = AsyncTool(name: name) == nil ? "" : " async=true"
            return [line("tool-call", "\(name)\(async) \(Self.json(args))")]
        case .toolDropped(let tool): return [line("tool-result", "\(tool.rawValue) dropped reason=reconnect")]
        case .toolResult(let name, let ok, let code, let data, let elapsed):
            let timing = elapsed.map { " scheduling=\(AsyncTool.scheduling) ms=\($0)" } ?? ""
            return [line("tool-result", "\(name)\(timing) ok=\(ok) code=\(code ?? "none") \(Self.json(data))")]
        case .correction(let reason): return settle(ms, reason: reason) + [line("correction", reason)]
        case .languageLine(let l):
            // The re-ask settles the voided reply like any correction.
            if case .correction = l { return settle(ms, reason: CorrectionReason.wrongLanguage.rawValue) + [line(l.kind, l.fields)] }
            return [line(l.kind, l.fields)]
        case .playbackStarted: return [line("playback", "started")]
        case .playbackFinished: return [line("playback", "finished")]
        case .generationComplete(let t): return [line("turn-end", "generationComplete turn=\(t)")]
        case .turnComplete(let t, let outcome):
            return end(t, ms) + [line("turn-end", "turnComplete turn=\(t) outcome=\(outcome)")]
        case .turnEnded(let reason): return [line("turn-end", "reason=\(reason.rawValue)")]
        case .search(let query): return [line("search", query ?? "")]
        case .searchExchange(let x): return Self.searchLines(x).map { line($0.kind, $0.content) }
        case .searchOutcome(let o): return Self.searchLine(o).map { [line($0.kind, $0.content)] } ?? []
        case .contextNote(let name): return [line("context-note", "destination=\(name ?? "none")")]
        case .screenHidden(let kind, let text):
            return [line("screen-hidden", "kind=\(kind.rawValue) text=\(ScreenLanguage.recordText(text))")]
        case .wakeToListening(let n): return [line("wake-to-listening", "ms=\(n)")]
        case .wakeUnused: return ["\(ms) wake-unused"]
        case .speakerCheck(let check): return [line("speaker-check", check.fields)]
        case .destSearch(let search): return [line("dest-search", search.fields)]
        case .voiceClause(let v): return [line("voice", v.fields)]
        case .voiceFailed(let v): return [line("voice-failed", v.fields)]
        case .voiceGemini(let v): return [line("voice", v.fields)]
        case .claimCut(let turn, let played): return [line("claim-cut", "turn=\(turn) played_ms=\(played)")]
        case .music(let text):
            let rest = text.hasPrefix("music ") ? String(text.dropFirst("music ".count)) : text
            return [line("music", rest)]
        case .sessionClosed(let c): return add(.session("closed \(c.fields)"), atMs: ms)
        case .sessionGaveUp(let since, let attempts, let code):
            return add(.session("gave-up ms=\(since) attempts=\(attempts) code=\(code.rawValue)"), atMs: ms)
        case .sessionResume(let handle, let result):
            return add(.session("resume handle=\(handle ? "yes" : "no") result=\(result.rawValue)"), atMs: ms)
        case .session(let what):
            // A session event ends every open turn: her words are never lost from the file.
            var out: [String] = []
            for id in open.keys.sorted(by: { open[$0]!.firstMs < open[$1]!.firstMs }) { out += end(id, ms) }
            return out + settle(ms, reason: nil) + [line("session", what)]
        }
    }

    /// Call when the file is closed, so the last turn gets its `reply-out`.
    public mutating func finish(atMs ms: Int64) -> [String] {
        var out: [String] = []
        for id in open.keys.sorted(by: { open[$0]!.firstMs < open[$1]!.firstMs }) { out += end(id, ms) }
        return out + settle(ms, reason: nil)
    }

    private mutating func begin(_ t: TurnID, _ ms: Int64) {
        current = t
        if open[t] == nil { open[t] = Turn(id: t, firstMs: ms) }
    }

    /// Marks go to the open turn, else to the ended one still waiting for its outcome.
    private mutating func mark(_ change: (inout Turn) -> Void) {
        if let current, var t = open[current] {
            change(&t)
            open[current] = t
        } else if var t = awaiting {
            change(&t)
            awaiting = t
        }
    }

    private mutating func end(_ id: TurnID, _ ms: Int64) -> [String] {
        guard var t = open.removeValue(forKey: id) else { return [] }
        if current == id { current = nil }
        let out = settle(ms, reason: nil)
        t.ended = true
        awaiting = t
        let reply = t.text.isEmpty ? [] : ["\(t.firstMs) reply turn=\(id) \(t.text.replacingOccurrences(of: "\n", with: " "))"]
        return out + reply
    }

    private mutating func settle(_ ms: Int64, reason: String?) -> [String] {
        guard let t = awaiting else { return [] }
        awaiting = nil
        let outcome: String
        if t.bargedIn {
            outcome = "stopped reason=barge_in"
        } else if t.flushed {
            outcome = "voided reason=\(reason ?? "none")"
        } else if t.spoke {
            outcome = t.held || t.spokeAfterEnd ? "held-released" : "released"
        } else {
            outcome = "not-spoken" + (reason.map { " then=\($0)" } ?? "")
        }
        return ["\(ms) reply-out turn=\(t.id) \(outcome)"]
    }

    /// §18 item 2: a body over 32,000 characters keeps its first 8,000 and last 24,000.
    public static let bodyLimit = 32_000
    static func cut(_ body: String) -> String {
        guard body.count > bodyLimit else { return body }
        return String(body.prefix(8_000)) + "…" + String(body.suffix(24_000))
    }

    static func searchLines(_ x: WebSearchExchange) -> [(kind: String, content: String)] {
        var out = [("search-request", "attempt=\(x.attempt) body=\(x.requestBody)")]
        if let error = x.error {
            out.append(("search-response", "attempt=\(x.attempt) error=\(error) ms=\(x.ms) urlError=\(x.urlError.map(String.init) ?? "none")"))
        } else {
            out.append(("search-response", "attempt=\(x.attempt) status=\(x.status.map(String.init) ?? "none") ms=\(x.ms) bytes=\(x.bytes) "
                        + "chunks=\(x.chunks) answerChars=\(x.answerChars) sources=\(x.sources) "
                        + "searchCount=\(x.searchCount.map(String.init) ?? "none") body=\(cut(x.responseBody ?? ""))"))
        }
        return out
    }

    static func searchLine(_ o: WebSearchOutcome) -> (kind: String, content: String)? {
        switch o {
        case .used(let ms, let attempts, _, let answer, let sources):
            return ("search-result", "ok ms=\(ms) attempts=\(attempts) answer=\(answer) sources=\(sources.joined(separator: ","))")
        case .failed(let reason, let ms, let code):
            return ("search-result", "failed reason=\(reason) ms=\(ms) code=\(code ?? "none")")
        case .date(let query, let target, let added, let check):
            return ("search-date", "query=\(query) target=\(target ?? "none") added=\(added ? "yes" : "no") check=\(check.rawValue)")
        case .place(let query, let sent, let added, let hint):
            return ("search-place", "query=\(query) sent=\(sent) added=\(added ? "yes" : "no") hint=\(hint ? "yes" : "no")")
        case .blocked(let reason):
            return ("search-blocked", "reason=\(reason)")
        }
    }

    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// §17 item 2: file names and which to delete.
public enum ConversationFiles {
    public static let keep = 50
    public static let directory = "conversations"

    /// `yyyyMMdd-HHmmss.txt` in the phone's local time.
    public static func name(for date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d.txt", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    public static func isRecord(_ name: String) -> Bool {
        name.range(of: #"^\d{8}-\d{6}\.txt$"#, options: .regularExpression) != nil
    }

    /// Oldest first beyond the newest `keep`; files of other names are left alone.
    public static func toDelete(_ names: [String], keep: Int = keep) -> [String] {
        let records = names.filter(isRecord).sorted()
        return Array(records.dropLast(keep))
    }
}

/// Where the record's lines go. Throws on a failed write.
public protocol RecordWriter: Sendable {
    func append(_ lines: [String]) throws
}

/// §17 item 6: a bounded queue between the event paths and the writer. `submit` never blocks or throws; when full,
/// lines are dropped and counted, and the count is written as `dropped=<n>` after the lines queued before them. A failed write
/// stops the record for the session.
public final class ConversationRecord: Sendable {
    public static let capacity = 2000

    private struct State {
        var recorder = ConversationRecorder()
        var queue: [String] = []
        var dropped = 0
        var stopped = false
    }

    private let state = Mutex(State())
    private let capacity: Int
    private let start: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant

    /// §17 item 1: nil when the setting is off, so nothing is created and nothing is written.
    public static func make(enabled: Bool, header: RecordHeader, capacity: Int = ConversationRecord.capacity,
                            now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) -> ConversationRecord? {
        enabled ? ConversationRecord(header: header, capacity: capacity, now: now) : nil
    }

    init(header: RecordHeader, capacity: Int, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.capacity = capacity
        self.now = now
        start = now()
        state.withLock { $0.queue = header.lines }
    }

    public var isStopped: Bool { state.withLock { $0.stopped } }

    /// From any path; cheap and synchronous.
    public func submit(_ event: RecordEvent) {
        let elapsed = now() - start
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        state.withLock { s in
            guard !s.stopped else { return }
            let lines = s.recorder.add(event, atMs: ms)
            for line in lines {
                if s.queue.count >= capacity { s.dropped += 1 } else { s.queue.append(line) }
            }
        }
    }

    /// Ends the record: the last turn's `reply-out` is queued for the final drain.
    public func close() {
        let elapsed = now() - start
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        state.withLock { s in
            guard !s.stopped else { return }
            for line in s.recorder.finish(atMs: ms) {
                if s.queue.count >= capacity { s.dropped += 1 } else { s.queue.append(line) }
            }
        }
    }

    /// Writes what is queued (called off the event paths). On a failed write the record stops; nothing is thrown.
    public func drain(to writer: any RecordWriter) {
        let lines: [String] = state.withLock { s in
            guard !s.stopped else { return [] }
            var out = s.queue
            if s.dropped > 0 { out.append("dropped=\(s.dropped)"); s.dropped = 0 }
            s.queue = []
            return out
        }
        guard !lines.isEmpty else { return }
        do { try writer.append(lines) } catch { state.withLock { $0.stopped = true; $0.queue = [] } }
    }
}
