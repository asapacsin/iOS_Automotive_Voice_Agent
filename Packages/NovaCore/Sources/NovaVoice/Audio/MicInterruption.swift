/// F-03 §14 (T-021q): another app took the microphone (Voice Memos, a call, WeChat voice). Apple's rule: on an
/// interruption the app stops and waits; at its end it resumes only with `shouldResume`, otherwise when the user comes
/// back. While interrupted, an engine configuration change never restarts the engine. Pure.
public struct MicInterruption: Sendable, Equatable {
    public private(set) var interrupted = false
    /// The interruption ended without `shouldResume`: resume when the app is active again.
    public private(set) var resumeOnActive = false

    public init() {}

    /// F-03 §14 item 2: a configuration-change restart is allowed only while not interrupted.
    public var allowsRestart: Bool { !interrupted }

    /// iOS: the interruption began. The line for the record.
    public mutating func began() -> String {
        interrupted = true
        resumeOnActive = false
        return "audio interrupted"
    }

    /// iOS: the interruption ended. True: resume now.
    public mutating func ended(shouldResume: Bool) -> (resume: Bool, line: String) {
        guard interrupted else { return (false, "audio interruption-ended resume=no") }
        if shouldResume {
            interrupted = false
            return (true, "audio interruption-ended resume=now")
        }
        resumeOnActive = true
        return (false, "audio interruption-ended resume=on-return")
    }

    /// The app became active. True: resume now.
    public mutating func becameActive() -> Bool {
        guard interrupted, resumeOnActive else { return false }
        interrupted = false
        resumeOnActive = false
        return true
    }

    /// The session stopped: nothing to resume.
    public mutating func reset() { self = MicInterruption() }
}
