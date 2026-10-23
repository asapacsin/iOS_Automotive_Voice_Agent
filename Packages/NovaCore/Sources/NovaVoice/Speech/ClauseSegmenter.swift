import Foundation

/// Cuts the streamed reply text into clauses for the assistant voice (`A/voice/ClauseSegmenter.kt`,
/// ADR-016). A clause is released at a sentence end at once, at a comma once it is long enough, and
/// at `maxChars` regardless. The first clause may be short so the voice starts early. Pure.
public struct ClauseSegmenter: Sendable {
    static let hard: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…", "\n"]
    static let soft: Set<Character> = ["，", ",", "、", "：", ":"]

    private let firstSoftChars: Int
    private let softChars: Int
    private let maxChars: Int
    private var pending = ""
    private var pendingCount = 0
    private var released = 0

    public init(firstSoftChars: Int = 3, softChars: Int = 12, maxChars: Int = 40) {
        self.firstSoftChars = firstSoftChars
        self.softChars = softChars
        self.maxChars = maxChars
    }

    /// Appends `chunk` and returns the clauses complete now, in order.
    public mutating func append(_ chunk: String) -> [String] {
        var out: [String] = []
        for c in chunk {
            pending.append(c)
            pendingCount += 1
            let cut: Bool
            if Self.hard.contains(c) { cut = true }
            else if Self.soft.contains(c) { cut = pendingCount >= (released == 0 ? firstSoftChars : softChars) }
            else { cut = pendingCount >= maxChars }
            if cut, let clause = take() { out.append(clause) }
        }
        return out
    }

    /// The rest of the reply at its end, or nil when nothing speakable is left.
    public mutating func flush() -> String? { take() }

    /// A new reply: forget any half clause of the previous one.
    public mutating func reset() {
        pending = ""
        pendingCount = 0
        released = 0
    }

    private mutating func take() -> String? {
        let text = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        pendingCount = 0
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        released += 1
        return text
    }
}
