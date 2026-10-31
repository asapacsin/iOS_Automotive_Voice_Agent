import NovaKit
import NovaPorts

/// The status chip (contracts/voice-agent.md §1, `A/ui/AssistantUiStateMapper.kt`).
public enum AssistantChip: String, Sendable, Hashable {
    case idle, processing, listening, speaking, error
}

extension SessionUIState {
    public var chip: AssistantChip {
        switch self {
        case .disconnected: .idle
        case .connecting, .reconnecting, .thinking: .processing
        case .listening, .userSpeaking: .listening
        case .speaking: .speaking
        case .error: .error
        }
    }
}

/// Timers the session owns. A token from an older epoch is ignored.
public struct SessionTimer: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case setupDeadline, reconnectDelay, offlineCap }
    public let kind: Kind
    public let epoch: Epoch
}

public enum SessionInput: Sendable, Hashable {
    /// Wake word or UI.
    case start
    /// Lifecycle DEEP_IDLE or the user: close and forget the resumption handle.
    case stop
    /// A provider event from the socket opened as `connection`. Events of older sockets are ignored.
    case realtime(RealtimeEvent, connection: Generation)
    /// Local VAD (F-04).
    case speechStarted
    case speechStopped
    /// Arbiter verdict on speech during playback (F-08).
    case bargeIn(qualified: Bool)
    case timerFired(SessionTimer)
    /// F-24 §14 item 1: `NetworkPathWatcher` (debounced). Not errors: they never count against the budget.
    case networkLost
    case networkRestored
}

public enum SessionEffect: Sendable, Hashable {
    case stateChanged(SessionUIState)
    /// Open socket `connection`, resuming with `handle` when there is one.
    case connect(connection: Generation, resume: String?)
    case close
    case schedule(SessionTimer, at: NovaInstant)
    case cancelTimer(SessionTimer.Kind)
    /// Terminal error: show the settings message for `code` (F-05 §10 row 3).
    case showConfigError(RealtimeErrorCode)
    case diagnostic(DiagnosticEvent)
    /// F-24 §14 item 4: the offline cap ended the session; the shell releases the microphone and audio session.
    case offlineEnded
}

/// `VoiceSessionController` + `VoiceSessionStateMachine` (F-05 core, F-24). Pure: no socket, no timers.
public struct VoiceSession: Sendable {
    public private(set) var state: SessionUIState = .disconnected
    /// In memory only; cleared on stop and on 1007 (`RESUME_UNAVAILABLE`).
    public private(set) var resumptionHandle: String?
    public private(set) var connection = Generation.initial
    public private(set) var policy: ReconnectPolicy
    /// F-24 §14 item 2: RECONNECTING with no network: no attempts are made or counted until it returns.
    public private(set) var waitingForNetwork = false
    /// The watcher's last word; online until it says otherwise.
    public private(set) var online = true
    /// Set while a reconnect is under way, so its setupComplete logs `resumed`.
    private var reconnecting = false
    private let tuning: RealtimeTuning
    private var timerEpoch = Epoch.initial
    /// Pending timers by kind, so a stale token can be told apart.
    private var timers: [SessionTimer.Kind: Epoch] = [:]

    public init(realtime: RealtimeTuning = RealtimeTuning(), reconnect: ReconnectTuning = ReconnectTuning()) {
        tuning = realtime
        policy = ReconnectPolicy(tuning: reconnect)
    }

    public mutating func handle(_ input: SessionInput, at now: NovaInstant) -> [SessionEffect] {
        switch input {
        case .start:
            guard state == .disconnected || state == .error else { return [] }
            policy.reset()
            // Item 2: started with no network, she waits for it under the same cap.
            if !online { return waitForNetwork(at: now) }
            return transition(to: .connecting) + openSocket(at: now)
        case .stop:
            guard state != .disconnected else { return [] }
            resumptionHandle = nil
            waitingForNetwork = false
            reconnecting = false
            connection = connection.next()  // late events of the closed socket are now stale
            return cancelAll() + [.close] + transition(to: .disconnected)
        case .realtime(let event, let source):
            guard source == connection, state != .disconnected, state != .error else { return [] }
            return realtime(event, at: now)
        case .speechStarted:
            return state == .listening ? transition(to: .userSpeaking) : []
        case .speechStopped:
            return state == .userSpeaking ? transition(to: .thinking) : []
        case .bargeIn(let qualified):
            guard state == .speaking else { return [] }
            return [.diagnostic(.bargeIn(qualified: qualified))] + (qualified ? transition(to: .userSpeaking) : [])
        case .timerFired(let timer):
            guard timers[timer.kind] == timer.epoch else { return [] }
            timers[timer.kind] = nil
            switch timer.kind {
            case .setupDeadline:
                return [.diagnostic(.setupTimeout)] + fail(.timeout, at: now)
            case .reconnectDelay:
                return openSocket(at: now)
            case .offlineCap:
                guard waitingForNetwork else { return [] }
                waitingForNetwork = false
                reconnecting = false
                resumptionHandle = nil
                return cancelAll() + [.diagnostic(.offlineCapReached), .offlineEnded] + transition(to: .disconnected)
            }
        case .networkLost:
            guard online else { return [] }
            online = false
            let lost: [SessionEffect] = [.diagnostic(.networkLost)]
            switch state {
            case .disconnected, .error: return lost
            default:
                guard !waitingForNetwork else { return lost }
                // The socket is gone with the path; its late errors are stale and count nothing.
                connection = connection.next()
                return lost + cancel(.setupDeadline) + cancel(.reconnectDelay) + [.close] + waitForNetwork(at: now)
            }
        case .networkRestored:
            guard !online else { return [] }
            online = true
            let restored: [SessionEffect] = [.diagnostic(.networkRestored)]
            guard waitingForNetwork else { return restored }
            // Item 2: one attempt at once, with the handle; the budget starts fresh from here.
            waitingForNetwork = false
            policy.reset()
            return restored + cancel(.offlineCap) + [.diagnostic(.offlineRestoreAttempt)] + openSocket(at: now)
        }
    }

    private mutating func waitForNetwork(at now: NovaInstant) -> [SessionEffect] {
        waitingForNetwork = true
        reconnecting = true
        return transition(to: .reconnecting) + schedule(.offlineCap, at: now + tuning.offlineWaitCap)
    }

    private mutating func realtime(_ event: RealtimeEvent, at now: NovaInstant) -> [SessionEffect] {
        switch event {
        case .setupComplete:
            guard state == .connecting || state == .reconnecting else { return [] }
            policy.reset()
            let resumed: [SessionEffect] = reconnecting ? [.diagnostic(.resumed(handle: resumptionHandle != nil))] : []
            reconnecting = false
            return cancel(.setupDeadline) + resumed + transition(to: .listening)
        case .resumptionHandle(let handle):
            resumptionHandle = handle
            return []
        case .responseStarted:
            return []
        case .replyAudio, .replyText:
            return state == .thinking || state == .listening ? transition(to: .speaking) : []
        case .responseDone, .interrupted:
            return state == .speaking || state == .thinking ? transition(to: .listening) : []
        case .goAway:
            // The server will close soon: move to a fresh socket now, resuming with the handle.
            return fail(.disconnect, at: now)
        case .failed(let error):
            return fail(error.code, at: now)
        case .closed:
            return fail(.connectionClosed, at: now)
        case .userTranscript, .toolCalls, .toolCallCancellation, .audioDone:
            return []
        }
    }

    /// One error per socket: the socket is abandoned at once, so a second error from it is stale.
    private mutating func fail(_ code: RealtimeErrorCode, at now: NovaInstant) -> [SessionEffect] {
        if code == .resumeUnavailable { resumptionHandle = nil }
        connection = connection.next()
        let base = cancel(.setupDeadline) + [.close]
        // Item 2: with no network a retryable failure waits for it instead of spending an attempt.
        if !online, code.isRetryable { return base + cancel(.reconnectDelay) + waitForNetwork(at: now) }
        switch policy.next(after: code) {
        case .retry(let attempt, let delay):
            reconnecting = true
            return base + transition(to: .reconnecting)
                + [.diagnostic(.reconnectAttempt(attempt: attempt, delay: delay))]
                + schedule(.reconnectDelay, at: now + delay)
        case .giveUp:
            resumptionHandle = nil
            reconnecting = false
            return base + cancelAll() + transition(to: .error) + (code.isRetryable ? [] : [.showConfigError(code)])
        }
    }

    private mutating func openSocket(at now: NovaInstant) -> [SessionEffect] {
        [.connect(connection: connection, resume: resumptionHandle)]
            + schedule(.setupDeadline, at: now + tuning.setupCompleteTimeout)
    }

    private mutating func transition(to next: SessionUIState) -> [SessionEffect] {
        guard next != state else { return [] }
        state = next
        return [.stateChanged(next), .diagnostic(.sessionState(next))]
    }

    private mutating func schedule(_ kind: SessionTimer.Kind, at deadline: NovaInstant) -> [SessionEffect] {
        timerEpoch = timerEpoch.next()
        timers[kind] = timerEpoch
        return [.schedule(SessionTimer(kind: kind, epoch: timerEpoch), at: deadline)]
    }

    private mutating func cancel(_ kind: SessionTimer.Kind) -> [SessionEffect] {
        timers.removeValue(forKey: kind) == nil ? [] : [.cancelTimer(kind)]
    }

    private mutating func cancelAll() -> [SessionEffect] {
        cancel(.setupDeadline) + cancel(.reconnectDelay) + cancel(.offlineCap)
    }
}
