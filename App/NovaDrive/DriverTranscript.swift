import Foundation
import NovaAgent
import NovaAudio
import NovaKit
import NovaPorts
import NovaVoice

/// F-05a (T-016c): the driver's words for AgentCore. The uplink's utterance marks and frames reach the phone's
/// recognizer in capture order; `TranscriptSelector` picks local text over Gemini's guess and sends the result
/// to the core as `.driverWords`.
actor DriverTranscript {
    enum Input: Sendable {
        case begin
        case frame(PCMFrame16k)
        case end
    }

    private let transcriber: any LocalTranscriber
    private let core: AgentCore
    private let clock: SystemClock
    private let onWords: @Sendable (DriverWords) -> Void
    private var selector = TranscriptSelector()
    private var next = 0
    private var open: UtteranceID?

    init(transcriber: any LocalTranscriber, core: AgentCore, clock: SystemClock,
         onWords: @escaping @Sendable (DriverWords) -> Void) {
        self.transcriber = transcriber
        self.core = core
        self.clock = clock
        self.onWords = onWords
    }

    /// Consumes the recognizer's results. Call once.
    func listen() async {
        for await event in transcriber.events {
            await route(selector.local(event, at: clock.now))
        }
    }

    func handle(_ input: Input) async {
        switch input {
        case .begin:
            next += 1
            let id = UtteranceID(next)
            open = id
            let ready: Bool
            switch await transcriber.availability {
            case .ready: ready = true
            case .unavailable: ready = false
            }
            await route(selector.begin(id, localReady: ready))
            if ready { await transcriber.begin(utterance: id) }
        case .frame(let frame):
            if open != nil { await transcriber.append(frame) }
        case .end:
            guard let id = open else { return }
            open = nil
            await transcriber.end(utterance: id)
            await route(selector.end(id, at: clock.now))
        }
    }

    /// Gemini's input transcript: only a fallback (S3), language-checked by the selector.
    func gemini(_ text: String, isFinal: Bool) async {
        await route(selector.gemini(text, isFinal: isFinal, at: clock.now))
    }

    private func deadline(_ id: UtteranceID) async {
        await route(selector.deadline(id, at: clock.now))
    }

    private func route(_ outputs: [TranscriptSelector.Output]) async {
        for output in outputs {
            switch output {
            case .words(let words):
                onWords(words)
                await core.send(.driverWords(words))
            case .schedule(let id, let at):
                let delay = max(0, at.milliseconds - clock.now.milliseconds)
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(delay))
                    await self?.deadline(id)
                }
            }
        }
    }
}
