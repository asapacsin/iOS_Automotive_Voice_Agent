import NovaKit
import NovaPorts

/// Turns decoded server parts into provider-neutral events in the order of contracts/voice-agent.md §4
/// (`GeminiLiveClient.onContent`). One assembler per connection; the reader task owns it.
public struct GeminiTurnAssembler: Sendable {
    private var nextTurn = TurnID.initial
    private var openTurn: TurnID?
    private var inputTranscript = ""
    private var stashedOutput: [String] = []

    public init() {}

    public mutating func consume(_ parts: [GeminiServerPart]) -> [RealtimeEvent] {
        parts.flatMap { consume($0) }
    }

    public mutating func consume(_ part: GeminiServerPart) -> [RealtimeEvent] {
        switch part {
        case .setupComplete:
            return [.setupComplete]
        case .resumption(let handle, let resumable):
            // Mid-generation the server reports resumable=false without a handle: the last good handle
            // still resumes the session, so only a new resumable handle is passed on.
            guard resumable, let handle else { return [] }
            return [.resumptionHandle(handle)]
        case .inputTranscript(let text):
            // Partials go out as they arrive (guards and the no-answer clock read them); rule 2 still
            // flushes the whole utterance as final when the turn opens.
            inputTranscript += text
            return [.userTranscript(text, isFinal: false)]
        case .outputTranscript(let text), .modelText(let text):
            // Rule 1: transcript before the turn opens is stashed until audio or a tool call opens it.
            guard let turn = openTurn else { stashedOutput.append(text); return [] }
            return [.replyText(turn, text)]
        case .modelAudio(let pcm):
            var events = open()
            events.append(.replyAudio(openTurn!, pcm))
            return events
        case .toolCalls(let calls):
            guard !calls.isEmpty else { return [] }
            var events = open()
            events.append(.toolCalls(openTurn!, calls))
            return events
        case .toolCallCancellation(let ids):
            return [.toolCallCancellation(ids)]
        case .generationComplete:
            guard let turn = openTurn else { return [] }
            return [.audioDone(turn)]
        case .interrupted:
            guard let turn = openTurn else { return [] }
            close()
            return [.interrupted(turn, reason: .serverVAD), .responseDone(turn, outcome: .cancelled)]
        case .turnComplete:
            guard let turn = openTurn else {
                // Nothing opened (e.g. a text-only reply): no response, and stale text does not leak forward.
                stashedOutput = []
                return []
            }
            close()
            return [.responseDone(turn, outcome: .completed)]
        case .goAway(let timeLeft):
            return [.goAway(timeLeft: timeLeft)]
        }
    }

    /// Rule 2: opening flushes the input transcript as `UserTranscript`, then `ResponseStarted`.
    private mutating func open() -> [RealtimeEvent] {
        guard openTurn == nil else { return [] }
        nextTurn = nextTurn.next()
        openTurn = nextTurn
        var events: [RealtimeEvent] = []
        if !inputTranscript.isEmpty { events.append(.userTranscript(inputTranscript, isFinal: true)) }
        events.append(.responseStarted(nextTurn))
        events += stashedOutput.map { .replyText(nextTurn, $0) }
        inputTranscript = ""
        stashedOutput = []
        return events
    }

    private mutating func close() {
        openTurn = nil
        inputTranscript = ""
        stashedOutput = []
    }
}
