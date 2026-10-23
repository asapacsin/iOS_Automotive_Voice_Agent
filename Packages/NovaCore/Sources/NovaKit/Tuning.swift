// Tunable constants. Defaults equal the Android values and each field cites its spec line.
// Debug builds may override them for iOS re-tuning (F-04 §13); release builds use the defaults.

/// contracts/voice-agent.md §3, `A/voice/SpeechUplinkGate.kt:299-377`.
public struct UplinkGateTuning: Sendable, Hashable {
    public var onset = NovaDuration.milliseconds(200)
    public var preRoll = NovaDuration.milliseconds(300)
    public var hangover = NovaDuration.milliseconds(1200)
    public var evidenceWindow = NovaDuration.milliseconds(600)
    public var rmsFloor: Double = 120
    public var noiseFactor: Double = 2.2
    public var initialNoiseRMS: Double = 80
    public var warmUp = NovaDuration.milliseconds(1500)
    /// Flagged: shorter than this with voiced ratio below `flagVoicedRatio`.
    public var flagMaxLength = NovaDuration.milliseconds(800)
    public var flagVoicedRatio: Double = 0.35
    /// Held: shorter than this with voiced ratio below `holdVoicedRatio`.
    public var holdMaxLength = NovaDuration.milliseconds(1200)
    public var holdVoicedRatio: Double = 0.60
    /// Digital silence sent before `audioStreamEnd`.
    public var closingSilence = NovaDuration.milliseconds(1500)
    public init() {}
}

/// contracts/audio.md, `A/voice/MicInputGain.kt:23`.
public struct MicGainTuning: Sendable, Hashable {
    public var maxGain: Double = 3.0
    public var targetPeak: Double = 12_000
    public var noiseFloor: Double = 250
    public var riseFactor: Double = 1.15
    public init() {}
}

/// contracts/voice-agent.md §2, `A/voice/ListeningLifecycle.kt`.
public struct ListeningLifecycleTuning: Sendable, Hashable {
    public var activeIdle = NovaDuration.seconds(30)
    public var silentWait = NovaDuration.seconds(20)
    public var sleepToDeepIdle = NovaDuration.minutes(5)
    /// A deadline that passed while busy fires this long after becoming idle.
    public var busyGrace = NovaDuration.milliseconds(1500)
    public init() {}
}

/// contracts/voice-agent.md §8, `I/ReconnectPolicy.kt`.
public struct ReconnectTuning: Sendable, Hashable {
    public var maxAttempts = 5
    public var initialDelay = NovaDuration.milliseconds(200)
    public var maxDelay = NovaDuration.seconds(8)
    /// Delay doubles after each failed attempt, capped at `maxDelay`.
    public var multiplier: Int64 = 2
    public init() {}

    /// Delay before `attempt` (1-based): 200, 400, 800 ms ... capped at 8 s.
    public func delay(beforeAttempt attempt: Int) -> NovaDuration {
        var delay = initialDelay
        for _ in 1..<max(attempt, 1) {
            delay = delay * multiplier
            if delay >= maxDelay { return maxDelay }
        }
        return delay
    }
}

/// contracts/api-contracts.md (Gemini).
public struct RealtimeTuning: Sendable, Hashable {
    public var connectTimeout = NovaDuration.seconds(10)
    public var setupCompleteTimeout = NovaDuration.seconds(10)
    public var pingInterval = NovaDuration.seconds(20)
    public var eventBufferLimit = 1024
    public init() {}
}

/// contracts/voice-agent.md §6.
public struct TruthfulnessTuning: Sendable, Hashable {
    public var holdBudgetEvents = 120
    public var correctionGraceToolMayFollow = NovaDuration.milliseconds(20_000)
    public var correctionGraceChat = NovaDuration.milliseconds(1500)
    public var emptyResponseReask = NovaDuration.seconds(3)
    public var emptyResponseGiveUp = NovaDuration.seconds(5)
    public var phantomMaxCJK = 12
    public var phantomMaxLatin = 40
    public var phantomMinTranscript = 2
    public init() {}
}

/// contracts/voice-agent.md §7, `A/voice/WaitCues.kt`.
public struct WaitCueTuning: Sendable, Hashable {
    public var visualCue = NovaDuration.seconds(3)
    public var spokenCue = NovaDuration.seconds(7)
    public var delayLine = NovaDuration.seconds(12)
    public var lostTurnWindow = NovaDuration.seconds(60)
    public init() {}
}

/// contracts/audio.md (`LowLatencyPlaybackBuffer`).
public struct PlaybackBufferTuning: Sendable, Hashable {
    public var maxIncreases = 5
    public var shrinkAfterTicks = 10
    public init() {}
}

/// contracts/api-contracts.md (Azure).
public struct AzureSpeechTuning: Sendable, Hashable {
    public var connectTimeout = NovaDuration.seconds(5)
    public var clauseDeadlineBase = NovaDuration.milliseconds(4000)
    public var clauseDeadlinePerChar = NovaDuration.milliseconds(400)
    public var warmUpInterval = NovaDuration.seconds(15)
    public var maxInFlight = 2
    public init() {}

    public func clauseDeadline(characters: Int) -> NovaDuration {
        clauseDeadlineBase + clauseDeadlinePerChar * Int64(characters)
    }
}

/// contracts/voice-agent.md §5, `A/voice/SpeechArbiter.kt`.
public struct ArbiterTuning: Sendable, Hashable {
    public var guidanceTail = NovaDuration.milliseconds(500)
    public var uplinkMaxClosed = NovaDuration.seconds(20)
    public var driverMidUtteranceKeepOpen = NovaDuration.seconds(8)
    public var navigatingPermittedWindow = NovaDuration.seconds(10)
    public var workloadHoldRadiusMeters = 150
    public var workloadHoldMax = NovaDuration.seconds(8)
    public var workloadDistanceJumpMeters = 20
    public init() {}
}

/// contracts/navigation.md, features/guidance-voice.md.
public struct GuidanceRelayTuning: Sendable, Hashable {
    public var deadline = NovaDuration.milliseconds(1200)
    public var cooldown = NovaDuration.seconds(60)
    public var consecutiveDeadlineFallbacksForCooldown = 2
    public var fidelityStrikeLimit = 2
    public var bracketPerChar = NovaDuration.milliseconds(300)
    public var bracketMin = NovaDuration.milliseconds(1500)
    public var echoWindow = NovaDuration.seconds(10)
    public init() {}
}

/// contracts/navigation.md.
public struct NavigationTuning: Sendable, Hashable {
    public var choiceExpiry = NovaDuration.milliseconds(120_000)
    public var maxChoiceIndex = 10
    public var localPickDuplicateWindow = NovaDuration.milliseconds(5000)
    public var requestWait = NovaDuration.milliseconds(10_000)
    public var optionsWait = NovaDuration.milliseconds(8000)
    public var destinationMaxLength = 120
    public var choiceNameMaxLength = 40
    public init() {}
}

/// contracts/api-contracts.md (Amap Web), features/destination-search.md.
public struct AmapWebTuning: Sendable, Hashable {
    public var aroundRadiusMeters = 50_000
    public var maxResults = 5
    public var corridorHalfWidthMeters = 500
    public var corridorSimplifyMeters = 50
    public var corridorMaxVertices = 64
    /// `offset` (results per page) on `/v3/place/polygon`.
    public var corridorPageSize = 25
    public var liveInfoTimeout = NovaDuration.milliseconds(4000)
    public var weatherTTL = NovaDuration.minutes(10)
    public var adcodeTTL = NovaDuration.minutes(30)
    public var locationFresh = NovaDuration.seconds(30)
    public var locationProvisional = NovaDuration.minutes(10)
    public var locationMaxAccuracyMeters = 2000
    public init() {}
}

/// features/ambiguity-context.md.
public struct DriverContextTuning: Sendable, Hashable {
    public var referentWindow = NovaDuration.seconds(180)
    public init() {}
}

/// contracts/navigation.md (Overspeed).
public struct OverspeedTuning: Sendable, Hashable {
    public var minGap = NovaDuration.milliseconds(10_000)
    public init() {}
}

/// features/wake-word.md §8 (`BoundedRetry`).
public struct WakeRetryTuning: Sendable, Hashable {
    public var base = NovaDuration.milliseconds(1500)
    public var max = NovaDuration.seconds(30)
    public var attempts = 6
    public var reconcileInterval = NovaDuration.milliseconds(1500)
    public init() {}
}
