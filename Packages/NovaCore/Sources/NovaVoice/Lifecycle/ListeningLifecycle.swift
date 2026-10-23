import NovaKit

/// Inputs to the listening lifecycle (contracts/voice-agent.md §2).
public enum LifecycleInput: Sendable, Hashable {
    /// Wake word or tap-to-talk.
    case wake
    /// A whole driver utterance, already classified. `.passToModel` counts as real speech.
    case utterance(ListeningIntent)
    /// The model called `end_conversation`.
    case endConversation
    /// Something is in progress (reply playing, tool running, turn open). Timers pause while busy.
    case busy(Bool)
    case navigating(Bool)
    /// Local VAD noise that did not become an utterance. Never extends a timer.
    case noise
    case timerFired(LifecycleTimer)
}

/// The single lifecycle timer. A token from an older epoch is ignored (`A/voice/ListeningLifecycle.kt`).
public struct LifecycleTimer: Sendable, Hashable {
    public let epoch: Epoch
}

public enum LifecycleEffect: Sendable, Hashable {
    case stateChanged(ListeningState)
    /// 「闭嘴」: stop the current reply now (the shell raises the playback epoch and flushes).
    case stopSpeaking
    case connect
    case disconnect
    /// Replaces any earlier schedule; the shell turns it into `.timerFired` at `at`.
    case schedule(LifecycleTimer, at: NovaInstant)
    case cancelTimer
}

/// ACTIVE / SILENT_WAIT / SLEEP / DEEP_IDLE (F-02). Pure: time comes in as an argument and every
/// side effect goes out as a `LifecycleEffect`.
public struct ListeningLifecycle: Sendable {
    public private(set) var state: ListeningState = .deepIdle
    public private(set) var isBusy = false
    public private(set) var isNavigating = false
    private let tuning: ListeningLifecycleTuning
    private var timerEpoch = Epoch.initial
    /// When the current state's timeout is due; nil in DEEP_IDLE.
    private var deadline: NovaInstant?

    public init(tuning: ListeningLifecycleTuning = ListeningLifecycleTuning()) {
        self.tuning = tuning
    }

    public mutating func handle(_ input: LifecycleInput, at now: NovaInstant) -> [LifecycleEffect] {
        switch input {
        case .wake:
            let connect = state == .deepIdle
            return (connect ? [.connect] : []) + enter(.active, at: now)
        case .utterance(let intent):
            return utterance(intent, at: now)
        case .endConversation:
            return state == .active || state == .silentWait ? enter(.sleep, at: now) : []
        case .busy(let busy):
            guard busy != isBusy else { return [] }
            isBusy = busy
            // Leaving busy: a deadline that passed meanwhile fires after the grace period.
            return busy ? [] : armTimer(at: now)
        case .navigating(let navigating):
            guard navigating != isNavigating else { return [] }
            isNavigating = navigating
            return state == .sleep && !navigating ? armTimer(at: now) : []
        case .noise:
            return []
        case .timerFired(let timer):
            guard timer.epoch == timerEpoch, let deadline, now >= deadline else { return [] }
            return timeout(at: now)
        }
    }

    private mutating func utterance(_ intent: ListeningIntent, at now: NovaInstant) -> [LifecycleEffect] {
        switch (state, intent) {
        case (.active, .shutUp):
            return [.stopSpeaking] + enter(.silentWait, at: now)
        case (.silentWait, .shutUp):
            return []
        case (.active, .goToSleep), (.silentWait, .goToSleep):
            return enter(.sleep, at: now)
        case (.silentWait, .passToModel):
            return enter(.active, at: now)
        case (.active, .passToModel):
            // Real speech restarts the 30 s idle window.
            deadline = now + tuning.activeIdle
            return armTimer(at: now)
        case (.sleep, _), (.deepIdle, _):
            // Asleep, nothing is uploaded; only wake brings her back.
            return []
        }
    }

    private mutating func timeout(at now: NovaInstant) -> [LifecycleEffect] {
        if isBusy { return [] }  // Re-armed when busy ends.
        switch state {
        case .active, .silentWait:
            return enter(.sleep, at: now)
        case .sleep:
            if isNavigating { return [] }  // Connection kept; re-armed when navigation ends.
            return enter(.deepIdle, at: now) + [.disconnect]
        case .deepIdle:
            return []
        }
    }

    private mutating func enter(_ next: ListeningState, at now: NovaInstant) -> [LifecycleEffect] {
        let changed = next != state
        state = next
        switch next {
        case .active: deadline = now + tuning.activeIdle
        case .silentWait: deadline = now + tuning.silentWait
        case .sleep: deadline = now + tuning.sleepToDeepIdle
        case .deepIdle: deadline = nil
        }
        return (changed ? [.stateChanged(next)] : []) + armTimer(at: now)
    }

    /// Schedules the timer for the current deadline. A deadline already past (it passed while busy or
    /// navigating) fires `busyGrace` from now. Busy holds the timer off entirely.
    private mutating func armTimer(at now: NovaInstant) -> [LifecycleEffect] {
        timerEpoch = timerEpoch.next()
        guard let deadline, !isBusy else { return [.cancelTimer] }
        let fireAt = deadline > now ? deadline : now + tuning.busyGrace
        self.deadline = fireAt
        return [.schedule(LifecycleTimer(epoch: timerEpoch), at: fireAt)]
    }
}
