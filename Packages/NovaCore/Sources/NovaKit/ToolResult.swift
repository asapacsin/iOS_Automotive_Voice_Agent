/// Error code returned to the model in an `ok=false` tool result. A closed enum: new codes are added
/// here, and no code can be built from runtime text, so diagnostics carrying one cannot leak text (I-8).
public enum ToolErrorCode: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    // F-09 dispatch and guards
    case validationError = "_validation_error"
    case unsupportedBodyPart = "UNSUPPORTED_BODY_PART"
    case ambiguousReferent = "AMBIGUOUS_REFERENT"
    case nearbyQuestionWhileNavigating = "NEARBY_QUESTION_WHILE_NAVIGATING"
    case vagueExitWhileNavigating = "VAGUE_EXIT_WHILE_NAVIGATING"
    /// M1 stub for tools without an iOS executor yet (name PROPOSED, ios-architecture §8).
    case notAvailableOnIOSYet = "NOT_AVAILABLE_ON_IOS_YET"

    // F-11 vehicle fault injection
    case unsupported = "UNSUPPORTED"
    case unavailable = "UNAVAILABLE"
    case permissionDenied = "PERMISSION_DENIED"
    case executionFailure = "EXECUTION_FAILURE"

    // F-15 / F-16 navigation
    case noCandidates = "NO_CANDIDATES"
    case homeNotSet = "HOME_NOT_SET"
    case workNotSet = "WORK_NOT_SET"
    case amapWebKeyMissing = "AMAP_WEB_KEY_MISSING"
    case optionsStale = "OPTIONS_STALE"
    case optionsNotReady = "OPTIONS_NOT_READY"
    case noOptionsOnScreen = "NO_OPTIONS_ON_SCREEN"
    case routeCalculationFailed = "ROUTE_CALCULATION_FAILED"
    case startFailed = "START_FAILED"

    // F-18 live info, F-19 phone
    case notNavigating = "NOT_NAVIGATING"
    case noTelephony = "NO_TELEPHONY"

    public var description: String { rawValue }
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
    /// No Gemini key stored (name PROPOSED; Android shows the settings card instead).
    case geminiKeyMissing = "GEMINI_KEY_MISSING"
    case audioCaptureFailed = "AUDIO_CAPTURE_FAILED"
}
