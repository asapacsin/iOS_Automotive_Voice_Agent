import Foundation
import NovaKit
import NovaPorts
import NovaVoice
import Synchronization

/// F-12 §17 (T-031f): one thing that happened in a conversation, as the test record sees it. Off by default; the
/// record is a local file, never a log (I-8, product-spec I-7/I-8 note). Pure.
public enum RecordEvent: Sendable, Hashable {
    /// The bundled recognizer's final words; nil = （没听清）.
    case heardLocal(String?)
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
    case toolResult(name: String, ok: Bool, code: String?, data: JSONValue)
    case correction(String)
    case playbackStarted
    case playbackFinished
    case bargeIn(stopped: Bool)
    case generationComplete(TurnID)
    case turnComplete(TurnID, outcome: String)
    case turnEnded(TurnEndReason)
    case session(String)
}

/// Header facts (§17 item 3). Never a key or the system instruction: there is no field for them.
public struct RecordHeader: Sendable, Hashable {
    public let appVersion: String
    public let comfortMode: String
    public let interruptible: Bool
    public let speakingStyle: String

    public init(appVersion: String, comfortMode: String, interruptible: Bool, speakingStyle: String) {
        self.appVersion = appVersion
        self.comfortMode = comfortMode
        self.interruptible = interruptible
        self.speakingStyle = speakingStyle
    }

    public var lines: [String] {
        ["app \(appVersion)", "comfortMode \(comfortMode)", "可以打断她 \(interruptible ? "on" : "off")",
         "speakingStyle \(speakingStyle)"]
    }
}

/// Turns events into lines (§17 item 4): `<ms> <kind> <content>`. Reply pieces are merged into one `reply` line per
/// turn, written when the turn ends, with the time of its first piece; `reply-out` follows it.
public struct ConversationRecorder: Sendable {
    private struct Turn: Sendable {
        var firstMs: Int64
        var text = ""
        var spoke = false
        var held = false
        var flushed = false
        var bargedIn = false
    }

    private var turns: [TurnID: Turn] = [:]
    private var current: TurnID?

    public init() {}

    public mutating func add(_ event: RecordEvent, atMs ms: Int64) -> [String] {
        func line(_ kind: String, _ content: String) -> String { "\(ms) \(kind) \(content)" }
        switch event {
        case .heardLocal(let words): return [line("heard-local", words ?? "（没听清）")]
        case .heardGemini(let text): return [line("heard-gemini", text)]
        case .utterance(let id, let sent, let mute): return [line("utterance", "id=\(id) sent=\(sent) mute=\(mute)")]
        case .turnStarted(let t):
            current = t
            if turns[t] == nil { turns[t] = Turn(firstMs: ms) }
            return []
        case .replyText(let t, let text):
            if turns[t] == nil { turns[t] = Turn(firstMs: ms) }
            turns[t]?.text += text
            return []
        case .spoke: mark { $0.spoke = true }; return []
        case .held: mark { $0.held = true }; return []
        case .flushed: mark { $0.flushed = true }; return []
        case .bargeIn(let stopped):
            if stopped { mark { $0.bargedIn = true } }
            return [line("barge-in", stopped ? "stopped" : "rejected")]
        case .toolCall(let name, let args): return [line("tool-call", "\(name) \(Self.json(args))")]
        case .toolResult(let name, let ok, let code, let data):
            return [line("tool-result", "\(name) ok=\(ok) code=\(code ?? "none") \(Self.json(data))")]
        case .correction(let reason): return [line("correction", reason)]
        case .playbackStarted: return [line("playback", "started")]
        case .playbackFinished: return [line("playback", "finished")]
        case .generationComplete(let t): return [line("turn-end", "generationComplete turn=\(t)")]
        case .turnComplete(let t, let outcome):
            return close(t, ms) + [line("turn-end", "turnComplete turn=\(t) outcome=\(outcome)")]
        case .turnEnded(let reason): return [line("turn-end", "reason=\(reason.rawValue)")]
        case .session(let what): return [line("session", what)]
        }
    }

    private mutating func mark(_ change: (inout Turn) -> Void) {
        guard let current, var t = turns[current] else { return }
        change(&t)
        turns[current] = t
    }

    private mutating func close(_ id: TurnID, _ ms: Int64) -> [String] {
        guard let t = turns.removeValue(forKey: id) else { return [] }
        if current == id { current = nil }
        var out: [String] = []
        if !t.text.isEmpty { out.append("\(t.firstMs) reply turn=\(id) \(t.text.replacingOccurrences(of: "\n", with: " "))") }
        let outcome: String
        if t.flushed, !t.bargedIn {
            outcome = "voided reason=\(t.held ? "claim_unproven" : "flushed")"
        } else if t.bargedIn {
            outcome = "stopped reason=barge_in"
        } else if t.spoke {
            outcome = t.held ? "held-released" : "released"
        } else {
            outcome = "not-spoken"
        }
        out.append("\(ms) reply-out turn=\(id) \(outcome)")
        return out
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
