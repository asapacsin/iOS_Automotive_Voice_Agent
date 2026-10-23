/// Error code returned to the model in an `ok=false` tool result. A closed vocabulary: new codes are
/// added here, never built from runtime text.
public struct ToolErrorCode: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // F-09 dispatch and guards
    public static let validationError = ToolErrorCode(rawValue: "_validation_error")
    public static let unsupportedBodyPart = ToolErrorCode(rawValue: "UNSUPPORTED_BODY_PART")
    public static let ambiguousReferent = ToolErrorCode(rawValue: "AMBIGUOUS_REFERENT")
    public static let nearbyQuestionWhileNavigating = ToolErrorCode(rawValue: "NEARBY_QUESTION_WHILE_NAVIGATING")
    public static let vagueExitWhileNavigating = ToolErrorCode(rawValue: "VAGUE_EXIT_WHILE_NAVIGATING")
    /// M1 stub for tools without an iOS executor yet (name PROPOSED, ios-architecture §8).
    public static let notAvailableOnIOSYet = ToolErrorCode(rawValue: "NOT_AVAILABLE_ON_IOS_YET")

    // F-11 vehicle fault injection
    public static let unsupported = ToolErrorCode(rawValue: "UNSUPPORTED")
    public static let unavailable = ToolErrorCode(rawValue: "UNAVAILABLE")
    public static let permissionDenied = ToolErrorCode(rawValue: "PERMISSION_DENIED")
    public static let executionFailure = ToolErrorCode(rawValue: "EXECUTION_FAILURE")

    // F-15 / F-16 navigation
    public static let noCandidates = ToolErrorCode(rawValue: "NO_CANDIDATES")
    public static let homeNotSet = ToolErrorCode(rawValue: "HOME_NOT_SET")
    public static let workNotSet = ToolErrorCode(rawValue: "WORK_NOT_SET")
    public static let amapWebKeyMissing = ToolErrorCode(rawValue: "AMAP_WEB_KEY_MISSING")
    public static let optionsStale = ToolErrorCode(rawValue: "OPTIONS_STALE")
    public static let optionsNotReady = ToolErrorCode(rawValue: "OPTIONS_NOT_READY")
    public static let noOptionsOnScreen = ToolErrorCode(rawValue: "NO_OPTIONS_ON_SCREEN")
    public static let routeCalculationFailed = ToolErrorCode(rawValue: "ROUTE_CALCULATION_FAILED")
    public static let startFailed = ToolErrorCode(rawValue: "START_FAILED")

    // F-18 live info, F-19 phone
    public static let notNavigating = ToolErrorCode(rawValue: "NOT_NAVIGATING")
    public static let noTelephony = ToolErrorCode(rawValue: "NO_TELEPHONY")
}

/// Result of one tool call. Every failure is `ok=false` with a code; nothing is thrown into the
/// session (ios-architecture §12).
public struct ToolResult: Sendable, Hashable {
    public let ok: Bool
    public let code: ToolErrorCode?
    /// Read-back payload sent to the model; also the source of the spoken announcement (I-14).
    public let data: [String: JSONValue]
    /// `ToolFailureAdvice` sentence the model should say on failure.
    public let advice: String?

    public init(ok: Bool, code: ToolErrorCode?, data: [String: JSONValue], advice: String?) {
        self.ok = ok
        self.code = code
        self.data = data
        self.advice = advice
    }

    public static func success(_ data: [String: JSONValue] = [:]) -> ToolResult {
        ToolResult(ok: true, code: nil, data: data, advice: nil)
    }

    public static func failure(_ code: ToolErrorCode, advice: String? = nil,
                               data: [String: JSONValue] = [:]) -> ToolResult {
        ToolResult(ok: false, code: code, data: data, advice: advice)
    }
}

/// Session-level codes shown in banners, not sent as tool results.
public enum SessionErrorCode: String, Sendable, Hashable {
    case geminiConsentMissing = "GEMINI_CONSENT_MISSING"
    case audioCaptureFailed = "AUDIO_CAPTURE_FAILED"
}
