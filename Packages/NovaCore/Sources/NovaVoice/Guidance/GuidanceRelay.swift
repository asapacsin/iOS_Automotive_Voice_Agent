import NovaKit

/// Why a guidance sentence went to the fallback voice instead of 小诺 (features/guidance-voice.md §5).
public enum GuidanceFallbackReason: String, Sendable, Hashable, CaseIterable {
    case disabled = "DISABLED"
    case expired = "EXPIRED"
    case notConnected = "NOT_CONNECTED"
    case noCapability = "NO_CAPABILITY"
    case driverSpeaking = "DRIVER_SPEAKING"
    case responseOpen = "RESPONSE_OPEN"
    case workPending = "WORK_PENDING"
    case amapSpeaking = "AMAP_SPEAKING"
    case focus = "FOCUS"
    case cooldown = "COOLDOWN"
    case fidelityStrikes = "FIDELITY_STRIKES"
    case sendFailed = "SEND_FAILED"
    case deadline = "DEADLINE"
}

/// What the relay needs to know about the session when it routes a sentence. AgentCore fills it.
public struct GuidanceConditions: Sendable, Hashable {
    /// `nova_guidance_relay/assistant_speaks_guidance`.
    public var enabled: Bool
    public var connected: Bool
    /// The provider can read a sentence back (revoicing on, text turns accepted).
    public var capable: Bool
    public var driverSpeaking: Bool
    /// A model reply is open (her voice is busy with something else).
    public var responseOpen: Bool
    /// A tool call is still running; its result will open a reply.
    public var workPending: Bool
    /// Audio focus is held (no interruption, route present).
    public var focusHeld: Bool

    public init(enabled: Bool = true, connected: Bool = true, capable: Bool = true, driverSpeaking: Bool = false,
                responseOpen: Bool = false, workPending: Bool = false, focusHeld: Bool = true) {
        self.enabled = enabled
        self.connected = connected
        self.capable = capable
        self.driverSpeaking = driverSpeaking
        self.responseOpen = responseOpen
        self.workPending = workPending
        self.focusHeld = focusHeld
    }
}

public enum GuidanceRelayOutput: Sendable, Hashable {
    /// Send `prompt` as a user text turn; the next model turn reads the sentence (ASSISTANT path).
    case sendToModel(GuidanceID, prompt: String)
    /// Speak `text` with the fallback voice on the guidance lane.
    case speakFallback(GuidanceID, text: String, reason: GuidanceFallbackReason)
    /// The model turn reading `id` must not be heard any more (it came too late): stop and silence it.
    case silenceAssistant(GuidanceID)
    /// Wake the relay at `at` (`deadlineFired` / `bracketFired`).
    case schedule(GuidanceID, at: NovaInstant)
    /// A fidelity strike was counted for `id` (the reading differed from the sentence).
    case fidelityStrike(GuidanceID, strikes: Int)
}

/// F-14 guidance relay (T-051, `A/nav/GuidanceRelay.kt`). Pure: time comes in as `now`, effects go
/// out. One sentence at a time, FIFO: QUEUED → PENDING (sent, waiting for her voice) → ASSISTANT, or
/// to the fallback voice with a reason. Every sentence is spoken exactly once, by one voice:
/// a PENDING sentence that misses the deadline is silenced on the model side before the fallback
/// speaks it.
///
/// PROPOSED (Android `GuidanceRelay.kt:41-53,97-109,261-300` is an EVIDENCE_REQUEST): the routing
/// order of the reasons, the prompt wording, EXPIRED for a sentence still queued past its deadline,
/// and fidelity as "normalised reading equals normalised sentence".
public struct GuidanceRelay: Sendable {
    public enum Phase: Sendable, Hashable {
        /// Sent to the model; her reading has not started.
        case pending(enqueued: NovaInstant)
        /// Her reading started; ends at `assistantFinished` or the bracket.
        case assistant(started: NovaInstant)
        /// The fallback voice speaks it; ends at `fallbackFinished`.
        case fallback
    }

    public struct Item: Sendable, Hashable {
        public let id: GuidanceID
        public let text: String
        public let enqueued: NovaInstant
    }

    public let tuning: GuidanceRelayTuning
    public private(set) var queue: [Item] = []
    public private(set) var current: (item: Item, phase: Phase)?
    public private(set) var consecutiveDeadlines = 0
    public private(set) var cooldownUntil: NovaInstant?
    public private(set) var fidelityStrikes = 0
    /// What her current reading said so far (output transcript of the relay turn).
    private var reading = ""
    /// Sentences she read, for the echo check: the uplink may hear her reading back.
    private var relayed: [(text: String, at: NovaInstant)] = []

    public init(tuning: GuidanceRelayTuning = GuidanceRelayTuning()) { self.tuning = tuning }

    public static func prompt(for text: String) -> String { "请一字不改地朗读下面这句导航提示，不要添加或省略任何内容：\(text)" }

    /// The current sentence is being read by her (PENDING or ASSISTANT).
    public var assistantID: GuidanceID? {
        guard let current else { return nil }
        if case .fallback = current.phase { return nil }
        return current.item.id
    }

    public var busy: Bool { current != nil }

    // MARK: Inputs

    /// Amap gave a sentence (`playNaviSoundString:`).
    public mutating func enqueue(_ text: String, id: GuidanceID, at now: NovaInstant,
                                 conditions: GuidanceConditions) -> [GuidanceRelayOutput] {
        queue.append(Item(id: id, text: text, enqueued: now))
        return next(at: now, conditions: conditions)
    }

    /// The model turn answering the PENDING prompt started speaking.
    public mutating func assistantStarted(at now: NovaInstant) -> [GuidanceRelayOutput] {
        guard let current, case .pending = current.phase else { return [] }
        consecutiveDeadlines = 0
        reading = ""
        self.current = (current.item, .assistant(started: now))
        let bracket = max(tuning.bracketMin, tuning.bracketPerChar * Int64(current.item.text.count))
        return [.schedule(current.item.id, at: now + bracket)]
    }

    /// Output transcript of the relay turn.
    public mutating func assistantText(_ text: String) {
        guard let current, case .assistant = current.phase else { return }
        reading += text
    }

    /// The relay turn ended (completed or cut). Judges fidelity and moves on.
    public mutating func assistantFinished(at now: NovaInstant, conditions: GuidanceConditions) -> [GuidanceRelayOutput] {
        guard let current, case .assistant = current.phase else { return [] }
        return finishAssistant(current.item, at: now, conditions: conditions)
    }

    /// The deadline or bracket timer of `id` fired.
    public mutating func timerFired(_ id: GuidanceID, at now: NovaInstant,
                                    conditions: GuidanceConditions) -> [GuidanceRelayOutput] {
        guard let current, current.item.id == id else { return [] }
        switch current.phase {
        case .pending(let enqueued):
            guard now >= enqueued + tuning.deadline else { return [] }
            consecutiveDeadlines += 1
            if consecutiveDeadlines >= tuning.consecutiveDeadlineFallbacksForCooldown {
                cooldownUntil = now + tuning.cooldown
                consecutiveDeadlines = 0
            }
            self.current = (current.item, .fallback)
            return [.silenceAssistant(id), .speakFallback(id, text: current.item.text, reason: .deadline)]
        case .assistant(let started):
            let bracket = max(tuning.bracketMin, tuning.bracketPerChar * Int64(current.item.text.count))
            guard now >= started + bracket else { return [] }
            // She did not finish within the bracket: judge what was heard and release the lane.
            return finishAssistant(current.item, at: now, conditions: conditions)
        case .fallback:
            return []
        }
    }

    /// Sending the prompt failed (socket closed between routing and send).
    public mutating func sendFailed(_ id: GuidanceID, at now: NovaInstant) -> [GuidanceRelayOutput] {
        guard let current, current.item.id == id, case .pending = current.phase else { return [] }
        self.current = (current.item, .fallback)
        return [.silenceAssistant(id), .speakFallback(id, text: current.item.text, reason: .sendFailed)]
    }

    /// The fallback voice finished `id` (guidance lane `guidanceEnded`), or could not speak it.
    public mutating func fallbackFinished(_ id: GuidanceID, at now: NovaInstant,
                                          conditions: GuidanceConditions) -> [GuidanceRelayOutput] {
        guard let current, current.item.id == id, case .fallback = current.phase else { return [] }
        self.current = nil
        return next(at: now, conditions: conditions)
    }

    /// The driver's final transcript equals a sentence she read in the last 10 s: it is her own voice
    /// coming back through the microphone. Dropped once.
    public mutating func isEcho(_ driverText: String, at now: NovaInstant) -> Bool {
        relayed.removeAll { now - $0.at > tuning.echoWindow }
        let heard = Self.normalised(driverText)
        guard !heard.isEmpty, let index = relayed.firstIndex(where: { Self.normalised($0.text) == heard }) else {
            return false
        }
        relayed.remove(at: index)
        return true
    }

    /// Navigation ended: strikes, cooldown and the queue belong to the trip.
    public mutating func tripEnded() -> [GuidanceRelayOutput] {
        let silenced = assistantID.map { [GuidanceRelayOutput.silenceAssistant($0)] } ?? []
        queue = []
        current = nil
        consecutiveDeadlines = 0
        cooldownUntil = nil
        fidelityStrikes = 0
        reading = ""
        return silenced
    }

    // MARK: Routing

    private mutating func next(at now: NovaInstant, conditions: GuidanceConditions) -> [GuidanceRelayOutput] {
        guard current == nil, !queue.isEmpty else { return [] }
        let item = queue.removeFirst()
        if let reason = fallbackReason(for: item, at: now, conditions: conditions) {
            current = (item, .fallback)
            return [.speakFallback(item.id, text: item.text, reason: reason)]
        }
        current = (item, .pending(enqueued: item.enqueued))
        return [.sendToModel(item.id, prompt: Self.prompt(for: item.text)),
                .schedule(item.id, at: item.enqueued + tuning.deadline)]
    }

    private func fallbackReason(for item: Item, at now: NovaInstant,
                                conditions: GuidanceConditions) -> GuidanceFallbackReason? {
        if !conditions.enabled { return .disabled }
        if now >= item.enqueued + tuning.deadline { return .expired }
        if !conditions.connected { return .notConnected }
        if !conditions.capable { return .noCapability }
        if fidelityStrikes >= tuning.fidelityStrikeLimit { return .fidelityStrikes }
        if let until = cooldownUntil, now < until { return .cooldown }
        if !conditions.focusHeld { return .focus }
        if conditions.driverSpeaking { return .driverSpeaking }
        if conditions.responseOpen { return .responseOpen }
        if conditions.workPending { return .workPending }
        return nil
    }

    private mutating func finishAssistant(_ item: Item, at now: NovaInstant,
                                          conditions: GuidanceConditions) -> [GuidanceRelayOutput] {
        var effects: [GuidanceRelayOutput] = []
        if Self.normalised(reading) != Self.normalised(item.text) {
            fidelityStrikes += 1
            effects.append(.fidelityStrike(item.id, strikes: fidelityStrikes))
        }
        relayed.append((item.text, now))
        reading = ""
        current = nil
        return effects + next(at: now, conditions: conditions)
    }

    /// Letters and digits only: punctuation, spaces and 「。」 do not make a reading unfaithful.
    static func normalised(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil })
        return String(kept)
    }
}
