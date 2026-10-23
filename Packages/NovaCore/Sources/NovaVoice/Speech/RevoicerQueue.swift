import NovaKit
import NovaPorts

public enum RevoicerInput: Sendable, Hashable {
    /// A judged clause of the current reply.
    case clause(String)
    /// Synthesis of clause `sequence` of reply `epoch` finished.
    case synthesized(epoch: Epoch, sequence: Int, Result<PCMBuffer, SpeechSynthesisError>)
    /// ResponseStarted: a failure of the previous reply no longer silences this one (Android resets
    /// `replyFailed` here). Nothing in flight is cut.
    case newReply
    /// Barge-in, Interrupted, Error, Closed, VOIDED or cancelCurrentReply: drop everything of this reply.
    case cancel(newEpoch: Epoch)
}

public enum RevoicerOutput: Sendable, Hashable {
    case synthesize(epoch: Epoch, sequence: Int, text: String, deadline: NovaDuration)
    /// Cancel an in-flight request (its result would be dropped anyway).
    case cancelSynthesis(epoch: Epoch, sequence: Int)
    case play(epoch: Epoch, sequence: Int, PCMBuffer)
    /// Once per reply: the rest of this reply is not spoken (the subtitle still shows).
    case failed(code: String)
}

/// The revoicer's clause pipeline (`AssistantVoiceRevoicer`, P48): a clause's request starts as soon
/// as its words are known, at most `maxInFlight` per reply; audio is released strictly in clause
/// order. A result of an older epoch is dropped. On failure the reply goes quiet; never a fallback to
/// the provider's own audio (ADR-016 §6). Pure.
public struct RevoicerQueue: Sendable {
    public private(set) var epoch: Epoch
    private let tuning: AzureSpeechTuning
    private var waiting: [(sequence: Int, text: String)] = []
    private var inFlight: Set<Int> = []
    private var ready: [Int: PCMBuffer] = [:]
    private var nextSequence = 0
    private var nextToPlay = 0
    private var failed = false

    public init(epoch: Epoch = .initial, tuning: AzureSpeechTuning = AzureSpeechTuning()) {
        self.epoch = epoch
        self.tuning = tuning
    }

    public mutating func handle(_ input: RevoicerInput) -> [RevoicerOutput] {
        switch input {
        case .clause(let text):
            guard !failed else { return [] }
            waiting.append((nextSequence, text))
            nextSequence += 1
            return startWaiting()
        case .synthesized(let e, let sequence, let result):
            guard e == epoch, inFlight.remove(sequence) != nil else { return [] }
            switch result {
            case .failure(let error):
                guard !failed else { return [] }
                failed = true
                waiting.removeAll()
                let cancels = inFlight.sorted().map { RevoicerOutput.cancelSynthesis(epoch: epoch, sequence: $0) }
                inFlight.removeAll()
                ready.removeAll()
                return cancels + [.failed(code: error.code)]
            case .success(let pcm):
                ready[sequence] = pcm
                var out: [RevoicerOutput] = []
                while let pcm = ready.removeValue(forKey: nextToPlay) {
                    out.append(.play(epoch: epoch, sequence: nextToPlay, pcm))
                    nextToPlay += 1
                }
                return out + startWaiting()
            }
        case .newReply:
            failed = false
            return []
        case .cancel(let newEpoch):
            let cancels = inFlight.sorted().map { RevoicerOutput.cancelSynthesis(epoch: epoch, sequence: $0) }
            self = RevoicerQueue(epoch: max(newEpoch, epoch.next()), tuning: tuning)
            return cancels
        }
    }

    /// Clauses queued, synthesising or synthesised but not yet released.
    public var pendingClauses: Int { waiting.count + inFlight.count + ready.count }

    private mutating func startWaiting() -> [RevoicerOutput] {
        var out: [RevoicerOutput] = []
        while inFlight.count < tuning.maxInFlight, !waiting.isEmpty {
            let (sequence, text) = waiting.removeFirst()
            inFlight.insert(sequence)
            out.append(.synthesize(epoch: epoch, sequence: sequence, text: text,
                                   deadline: tuning.clauseDeadline(characters: text.count)))
        }
        return out
    }
}
