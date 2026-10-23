import NovaKit
import NovaPorts

/// Imperative shell around `RevoicerQueue` (ios-architecture §5.1 "Revoicer" actor): runs the
/// synthesis requests, cancels them on barge-in, and hands audio to the reply lane in order.
public actor Revoicer {
    private let synthesizer: any SpeechSynthesizer
    private let playback: any PlaybackPort
    private let style: @Sendable () -> SpeakingStyle
    private let onFailure: @Sendable (String) -> Void
    private var queue: RevoicerQueue
    private var tasks: [Int: Task<Void, Never>] = [:]

    public init(synthesizer: any SpeechSynthesizer, playback: any PlaybackPort, epoch: Epoch = .initial,
                style: @escaping @Sendable () -> SpeakingStyle = { .default },
                onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.synthesizer = synthesizer
        self.playback = playback
        self.style = style
        self.onFailure = onFailure
        queue = RevoicerQueue(epoch: epoch)
    }

    public var epoch: Epoch { queue.epoch }

    public func newReply() { apply(queue.handle(.newReply)) }

    public func speak(_ clause: String) {
        guard let text = speakableText(clause) else { return }
        apply(queue.handle(.clause(text)))
    }

    /// Barge-in or a voided reply: in-flight requests are cancelled and nothing of the old epoch plays.
    public func cancel(newEpoch: Epoch) { apply(queue.handle(.cancel(newEpoch: newEpoch))) }

    private func finished(_ epoch: Epoch, _ sequence: Int, _ result: Result<PCMBuffer, SpeechSynthesisError>) {
        if epoch == queue.epoch { tasks[sequence] = nil }
        apply(queue.handle(.synthesized(epoch: epoch, sequence: sequence, result)))
    }

    private func apply(_ outputs: [RevoicerOutput]) {
        for output in outputs {
            switch output {
            case .synthesize(let epoch, let sequence, let text, let deadline):
                let synthesizer = synthesizer
                let style = style()
                tasks[sequence] = Task {
                    let result: Result<PCMBuffer, SpeechSynthesisError>
                    do {
                        result = .success(try await synthesizer.synthesize(text, style: style, deadline: deadline))
                    } catch let error as SpeechSynthesisError {
                        result = .failure(error)
                    } catch {
                        // Cancelled: the queue already moved on. Anything else is a failure, never a stall.
                        if Task.isCancelled { return }
                        result = .failure(SpeechSynthesisError("ASSISTANT_VOICE_FAILED"))
                    }
                    self.finished(epoch, sequence, result)
                }
            case .cancelSynthesis(_, let sequence):
                tasks.removeValue(forKey: sequence)?.cancel()
            case .play(let epoch, let sequence, let pcm):
                playback.enqueueReply(pcm, epoch: epoch, sequence: sequence)
            case .failed(let code):
                onFailure(code)
            }
        }
    }
}
