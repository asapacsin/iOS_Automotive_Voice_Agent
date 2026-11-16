/// F-03 §14 (T-021q): another app took the microphone (Voice Memos, a call, WeChat voice). Apple's rule: on an
/// interruption the app stops and waits; at its end it resumes only with `shouldResume`, otherwise when the user comes
/// back. Apple does not promise an end for every began, so becoming active also resumes an interruption with no end.
/// While interrupted, and until a resume has reactivated the session, a configuration change never restarts the
/// engine. Pure.
public struct MicInterruption: Sendable, Equatable {
    public private(set) var interrupted = false
    /// A resume was asked for and has not yet reactivated the session.
    public private(set) var resuming = false

    public init() {}

    /// F-03 §14 item 2: a configuration-change restart is allowed only while not interrupted.
    public var allowsRestart: Bool { !interrupted }

    /// iOS: the interruption began. The line for the record; nil when iOS reports it only because the app was
    /// suspended (`appWasSuspended`): nothing took the microphone, and no end will follow.
    public mutating func began(appWasSuspended: Bool = false) -> String? {
        if appWasSuspended { return nil }
        interrupted = true
        resuming = false
        return "audio interrupted"
    }

    /// iOS: the interruption ended. `resume` true: resume now. A stray end (not interrupted) changes nothing and
    /// writes no line.
    public mutating func ended(shouldResume: Bool) -> (resume: Bool, line: String)? {
        guard interrupted else { return nil }
        if shouldResume, !resuming {
            resuming = true
            return (true, "audio interruption-ended resume=now")
        }
        return (false, "audio interruption-ended resume=on-return")
    }

    /// The app became active. True: resume now (once until it succeeds or fails).
    public mutating func becameActive() -> Bool {
        guard interrupted, !resuming else { return false }
        resuming = true
        return true
    }

    /// The session was reactivated: the engine may start again.
    public mutating func resumed() {
        interrupted = false
        resuming = false
    }

    /// Reactivation failed: still interrupted; wait for the next return to the app.
    public mutating func resumeFailed() { resuming = false }

    /// The session stopped: nothing to resume.
    public mutating func reset() { self = MicInterruption() }
}
