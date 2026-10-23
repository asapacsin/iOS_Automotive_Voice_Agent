import NovaKit

/// A function the model may call. Names and schemas stay byte-for-byte equal to Android (F-09).
public struct ToolDeclaration: Sendable, Hashable {
    public let name: String
    public let description: String
    public let parametersJSONSchema: JSONValue

    public init(name: String, description: String, parametersJSONSchema: JSONValue) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }
}

public struct ToolCall: Sendable, Hashable {
    public let id: CallID
    public let name: String
    public let arguments: JSONValue

    public init(id: CallID, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResponse: Sendable, Hashable {
    public let id: CallID
    public let name: String
    public let result: ToolResult

    public init(id: CallID, name: String, result: ToolResult) {
        self.id = id
        self.name = name
        self.result = result
    }
}

public struct TextTurn: Sendable, Hashable {
    public enum Role: String, Sendable { case user, model }
    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// Provider-side voice activity detection settings (contracts/api-contracts.md, Gemini setup).
public struct ActivityDetectionConfig: Sendable, Hashable {
    public enum Sensitivity: String, Sendable { case low, high }
    public var startSensitivity: Sensitivity = .low
    public var endSensitivity: Sensitivity = .high
    /// 100...3000 ms when set.
    public var silenceDuration: NovaDuration?
    public init() {}
}

/// Provider-neutral session setup; NovaRealtime encodes it as Gemini `setup`.
public struct SessionConfig: Sendable, Hashable {
    public static let maxInstructionCharacters = 4000

    public var model: String
    public var systemInstruction: String
    public var tools: [ToolDeclaration]
    public var voiceName: String
    public var languageCode: String
    public var thinkingLevel: String?
    public var activityDetection: ActivityDetectionConfig
    public var inputTranscription: Bool
    public var outputTranscription: Bool

    public init(model: String = "gemini-3.8-live", systemInstruction: String, tools: [ToolDeclaration],
                voiceName: String = "Leda", languageCode: String = "zh-CN", thinkingLevel: String? = "LOW",
                activityDetection: ActivityDetectionConfig = ActivityDetectionConfig(),
                inputTranscription: Bool = true, outputTranscription: Bool = true) {
        self.model = model
        self.systemInstruction = systemInstruction
        self.tools = tools
        self.voiceName = voiceName
        self.languageCode = languageCode
        self.thinkingLevel = thinkingLevel
        self.activityDetection = activityDetection
        self.inputTranscription = inputTranscription
        self.outputTranscription = outputTranscription
    }
}

/// What the active provider can and cannot do; Gemini has no server speech events and no client cancel.
public struct RealtimeCapabilities: Sendable, Hashable {
    public let serverSpeechEvents: Bool
    public let clientCancel: Bool
    public let verbatimRelay: Bool

    public init(serverSpeechEvents: Bool, clientCancel: Bool, verbatimRelay: Bool) {
        self.serverSpeechEvents = serverSpeechEvents
        self.clientCancel = clientCancel
        self.verbatimRelay = verbatimRelay
    }
}

/// Classified provider errors (contracts/voice-agent.md §8).
public enum RealtimeErrorCode: String, Sendable, Hashable, CaseIterable {
    // Retryable
    case disconnect = "DISCONNECT"
    case connection = "CONNECTION"
    case dns = "DNS"
    case timeout = "TIMEOUT"
    case wsFailed = "WS_FAILED"
    case tlsFailed = "TLS_FAILED"
    case unavailable = "UNAVAILABLE"
    case resumeUnavailable = "RESUME_UNAVAILABLE"
    case connectionClosed = "CONNECTION_CLOSED"
    // Terminal
    case auth = "AUTH"
    case credential = "CREDENTIAL"
    case quota = "QUOTA"
    case rateLimited = "RATE_LIMITED"
    case malformed = "MALFORMED"
    case invalidModel = "INVALID_MODEL"

    public var isRetryable: Bool {
        switch self {
        case .disconnect, .connection, .dns, .timeout, .wsFailed, .tlsFailed, .unavailable,
             .resumeUnavailable, .connectionClosed:
            return true
        case .auth, .credential, .quota, .rateLimited, .malformed, .invalidModel:
            return false
        }
    }
}

public struct RealtimeError: Error, Sendable, Hashable {
    public let code: RealtimeErrorCode
    public init(_ code: RealtimeErrorCode) { self.code = code }
    public var isRetryable: Bool { code.isRetryable }
}

public enum InterruptReason: String, Sendable, Hashable {
    case serverVAD = "server_vad"
    case bargeIn = "barge_in"
}

public enum TurnOutcome: String, Sendable, Hashable {
    case completed, cancelled
}

/// Provider-neutral event names (contracts/voice-agent.md §4).
public enum RealtimeEvent: Sendable, Hashable {
    case setupComplete
    case userTranscript(String, isFinal: Bool)
    case responseStarted(TurnID)
    case replyText(TurnID, String)
    /// Dropped inside the adapter while revoicing.
    case replyAudio(TurnID, PCMBuffer)
    case toolCalls(TurnID, [ToolCall])
    case toolCallCancellation([CallID])
    /// `generationComplete`
    case audioDone(TurnID)
    case interrupted(TurnID, reason: InterruptReason)
    case responseDone(TurnID, outcome: TurnOutcome)
    case resumptionHandle(String?)
    case goAway(timeLeft: NovaDuration?)
    case failed(RealtimeError)
    case closed
}

/// The only realtime surface app logic sees (I-13).
public protocol RealtimeProvider: Sendable {
    var capabilities: RealtimeCapabilities { get }
    var events: AsyncStream<RealtimeEvent> { get }
    func connect(_ config: SessionConfig, resume handle: String?) async
    /// Data plane: non-blocking enqueue from the capture queue.
    func sendAudio(_ frame: PCMFrame16k)
    func sendAudioStreamEnd() async
    func sendToolResponses(_ responses: [ToolResponse]) async
    func sendText(_ turns: [TextTurn], turnComplete: Bool) async
    func close() async
}

/// Never printed: `description`, `debugDescription` and reflection all redact the secret (I-7).
public enum RealtimeCredential: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    case apiKey(String)
    case ephemeralToken(String)

    public var description: String {
        switch self {
        case .apiKey: "RealtimeCredential.apiKey(<redacted>)"
        case .ephemeralToken: "RealtimeCredential.ephemeralToken(<redacted>)"
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}

/// API key from the Keychain now; ephemeral token from an owner backend later (OQ-IOS-15).
public protocol RealtimeCredentialSource: Sendable {
    func credential() async throws -> RealtimeCredential
}
