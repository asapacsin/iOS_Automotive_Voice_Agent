import NovaKit

/// F-09b §6 (T-016p): the last completed exchanges of the conversation, in memory only (I-7: never written to disk,
/// never logged). A new session started without a resumption handle within 30 minutes gets them as one silent note.
/// Pure.
public struct ExchangeMemory: Sendable {
    public static let capacity = 6
    public static let maxCharacters = 60
    public static let window = NovaDuration.seconds(30 * 60)

    private var kept: [ConversationExchange] = []
    private var lastAt: NovaInstant?

    public init() {}

    public var count: Int { kept.count }

    /// §6 item 1: each text cut to 60 characters; only the last 6 are kept. An exchange after 30 minutes of none
    /// starts afresh (§6 item 3).
    public mutating func add(_ e: ConversationExchange, at now: NovaInstant) {
        if let lastAt, now - lastAt > Self.window { kept = [] }
        kept.append(ConversationExchange(driver: String(e.driver.prefix(Self.maxCharacters)),
                                         reply: String(e.reply.prefix(Self.maxCharacters)), tools: e.tools))
        if kept.count > Self.capacity { kept.removeFirst(kept.count - Self.capacity) }
        lastAt = now
    }

    /// §6 item 3: 结束对话 (and app restart, which starts empty).
    public mutating func clear() {
        kept = []
        lastAt = nil
    }

    /// §6 item 2: the note for a new session without a handle; nil when nothing is kept or the last exchange is
    /// older than 30 minutes (which also drops what is kept).
    public mutating func summary(at now: NovaInstant) -> SessionSummary? {
        guard let lastAt, !kept.isEmpty else { return nil }
        let age = now - lastAt
        guard age <= Self.window else {
            clear()
            return nil
        }
        let lines = kept.map { e -> String in
            let tools = e.tools.isEmpty ? "" : "（" + e.tools.joined(separator: "，") + "）"
            return "司机「\(e.driver)」→ 你「\(e.reply)」" + tools
        }
        let text = "[系统] 接着之前的对话。最近几句：" + lines.joined(separator: "；") + "。这句不用回答。"
        return SessionSummary(text: text, exchanges: kept.count, ageS: Int(age.milliseconds / 1000))
    }
}
