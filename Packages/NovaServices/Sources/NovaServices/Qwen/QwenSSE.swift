import Foundation

/// F-07 §14 item 3 (T-020a): one server-sent event, its `data:` lines joined with "\n".
public struct QwenSSEEvent: Sendable, Hashable {
    public let data: String
}

/// Splits the stream on the blank line and joins each event's `data:` lines before any JSON parsing, so a
/// `data:` line that arrives split across reads is still whole (measured 2026-11-06: 2 of 8 runs). Pure.
public struct QwenSSEParser: Sendable {
    private var pending = Data()

    public init() {}

    /// Bytes as they arrive; returns the events completed by them.
    public mutating func feed(_ bytes: Data) -> [QwenSSEEvent] {
        pending.append(bytes)
        var events: [QwenSSEEvent] = []
        while let end = Self.blankLine(in: pending) {
            let block = pending.subdata(in: pending.startIndex..<end.lowerBound)
            pending = pending.subdata(in: end.upperBound..<pending.endIndex)
            if let event = Self.event(block) { events.append(event) }
        }
        return events
    }

    /// The end of the stream: a last event with no blank line after it.
    public mutating func finish() -> [QwenSSEEvent] {
        defer { pending = Data() }
        return Self.event(pending).map { [$0] } ?? []
    }

    private static func blankLine(in data: Data) -> Range<Data.Index>? {
        let bytes = [UInt8](data)
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x0A, bytes[i + 1] == 0x0A { return data.index(data.startIndex, offsetBy: i)..<data.index(data.startIndex, offsetBy: i + 2) }
            if i + 3 < bytes.count, bytes[i] == 0x0D, bytes[i + 1] == 0x0A, bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A {
                return data.index(data.startIndex, offsetBy: i)..<data.index(data.startIndex, offsetBy: i + 4)
            }
            i += 1
        }
        return nil
    }

    private static func event(_ block: Data) -> QwenSSEEvent? {
        let text = String(decoding: block, as: UTF8.self)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        let data = lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            let value = line.dropFirst(5)
            return String(value.hasPrefix(" ") ? value.dropFirst() : value)
        }
        return data.isEmpty ? nil : QwenSSEEvent(data: data.joined(separator: "\n"))
    }
}

/// What one event means to the client.
public enum QwenTTSEvent: Sendable, Hashable {
    /// A `sentence-synthesis` event's decoded audio bytes.
    case audio(Data)
    /// Any other event (`sentence-begin`, `sentence-end`, the final event with `url`).
    case other
    /// Not JSON, bad base64, or a non-empty error `code`: `QWEN_TTS_BAD_STREAM`.
    case bad
}

public enum QwenTTSEventDecoder {
    public static func decode(_ event: QwenSSEEvent) -> QwenTTSEvent {
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else { return .bad }
        if let code = object["code"] as? String, !code.isEmpty { return .bad }
        guard let output = object["output"] as? [String: Any] else { return .other }
        guard output["type"] as? String == "sentence-synthesis" else { return .other }
        guard let audio = output["audio"] as? [String: Any], let b64 = audio["data"] as? String else { return .other }
        guard let bytes = Data(base64Encoded: b64) else { return .bad }
        return .audio(bytes)
    }
}

/// F-07 §14 item 3 "Long clauses": a clause over the limit is cut at the last `。！？；，` before the limit, or at
/// the limit when there is none. Pure.
public enum QwenTextCutter {
    static let marks: Set<Character> = ["。", "！", "？", "；", "，"]

    public static func pieces(_ text: String, limit: Int) -> [String] {
        precondition(limit > 0)
        var rest = Substring(text)
        var out: [String] = []
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: { marks.contains($0) }).map { window.index(after: $0) } ?? window.endIndex
            out.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }
}
