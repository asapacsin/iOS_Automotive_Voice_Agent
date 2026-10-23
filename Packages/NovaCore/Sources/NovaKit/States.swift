/// Session UI states (contracts/voice-agent.md §1, `I/VoiceUiState.kt`).
public enum SessionUIState: String, Sendable, Hashable, CaseIterable {
    case disconnected, connecting, listening, userSpeaking, thinking, speaking, reconnecting, error
}

/// Listening lifecycle states (contracts/voice-agent.md §2).
public enum ListeningState: String, Sendable, Hashable, CaseIterable {
    case active, silentWait, sleep, deepIdle

    /// Audio is uploaded only in ACTIVE and SILENT_WAIT.
    public var uploadsAudio: Bool { self == .active || self == .silentWait }
    /// Replies are spoken only in ACTIVE.
    public var speaksReplies: Bool { self == .active }
}

/// Navigation phases (contracts/navigation.md). There is no CANCELLED phase: cancel resets to IDLE.
public enum NavigationPhase: String, Sendable, Hashable, CaseIterable {
    case idle, resolvingDestination, awaitingDestinationSelection, planningRoute, calculatingRoute,
         awaitingRouteSelection, routeReady, navigating, arrived, stopped, error

    /// "Session active" = PLANNING_ROUTE, CALCULATING_ROUTE, ROUTE_READY, NAVIGATING.
    public var isSessionActive: Bool {
        switch self {
        case .planningRoute, .calculatingRoute, .routeReady, .navigating: return true
        default: return false
        }
    }
}

/// What a choice list on screen is choosing between.
public enum ChoiceListKind: String, Sendable, Hashable {
    case destinations, routes
}

/// Navigation state as mirrored into AgentCore and the UI. Nobody reads navigation state
/// synchronously across actors (ios-architecture §9.1).
public struct NavigationSnapshot: Sendable, Hashable {
    public var phase: NavigationPhase
    public var generation: Generation
    public var openList: ChoiceListKind?
    /// True while an along-route list is open and the current guidance is kept.
    public var guidanceKept: Bool
    public var distanceToManeuverMeters: Int?
    public var remainingMeters: Int?
    public var remainingSeconds: Int?

    public init(phase: NavigationPhase = .idle, generation: Generation = .initial,
                openList: ChoiceListKind? = nil, guidanceKept: Bool = false,
                distanceToManeuverMeters: Int? = nil, remainingMeters: Int? = nil,
                remainingSeconds: Int? = nil) {
        self.phase = phase
        self.generation = generation
        self.openList = openList
        self.guidanceKept = guidanceKept
        self.distanceToManeuverMeters = distanceToManeuverMeters
        self.remainingMeters = remainingMeters
        self.remainingSeconds = remainingSeconds
    }

    public var isNavigating: Bool { phase == .navigating }
}
