import Foundation
import Testing
@testable import NovaKit

@Suite("T-010 NovaKit time")
struct TimeTests {
    @Test("instant and duration arithmetic in milliseconds")
    func arithmetic() {
        let t = NovaInstant.zero + .seconds(30)
        #expect(t.milliseconds == 30_000)
        #expect(t - NovaInstant.zero == .milliseconds(30_000))
        #expect(NovaDuration.minutes(5) == .seconds(300))
        #expect(NovaDuration.milliseconds(400) * 3 == .milliseconds(1200))
    }

    @Test("manual clock resumes a sleeper only when time reaches its deadline")
    func manualClockSleep() async throws {
        let clock = ManualClock()
        let task = Task { try await clock.sleep(until: NovaInstant.zero + .seconds(3)) }
        while clock.pendingSleepers == 0 { await Task.yield() }
        clock.advance(by: .seconds(2))
        #expect(clock.pendingSleepers == 1)
        clock.advance(by: .seconds(1))
        try await task.value
        #expect(clock.pendingSleepers == 0)
        #expect(clock.now == NovaInstant.zero + .seconds(3))
    }

    @Test("manual clock sleep past deadline returns at once")
    func pastDeadline() async throws {
        let clock = ManualClock(start: NovaInstant(milliseconds: 10))
        try await clock.sleep(until: .zero)
    }

    @Test("cancelling a sleeper throws CancellationError")
    func cancellation() async {
        let clock = ManualClock()
        let task = Task { try await clock.sleep(until: NovaInstant.zero + .seconds(60)) }
        while clock.pendingSleepers == 0 { await Task.yield() }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.pendingSleepers == 0)
    }

    @Test("cancelling finished, waiting and unstarted sleeps leaves no bookkeeping behind")
    func noBookkeepingLeak() async {
        let clock = ManualClock()
        // Finished, then cancelled.
        let done = Task { try await clock.sleep(until: NovaInstant.zero + .seconds(1)) }
        while clock.pendingSleepers == 0 { await Task.yield() }
        clock.advance(by: .seconds(1))
        _ = await done.result
        done.cancel()
        // Cancelled before it starts sleeping.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(until: NovaInstant.zero + .seconds(60))
        }
        _ = await early.result
        // Cancelled while waiting.
        let waiting = Task { try await clock.sleep(until: NovaInstant.zero + .seconds(60)) }
        while clock.pendingSleepers == 0 { await Task.yield() }
        waiting.cancel()
        _ = await waiting.result
        #expect(clock.pendingSleepers == 0)
        #expect(clock.retainedBookkeeping == 0)
    }

    @Test("advance never moves time backwards")
    func monotonic() {
        let clock = ManualClock(start: NovaInstant(milliseconds: 100))
        clock.advance(to: NovaInstant(milliseconds: 50))
        #expect(clock.now.milliseconds == 100)
    }

    @Test("system clock is monotonic")
    func systemClock() {
        let clock = SystemClock()
        let a = clock.now
        let b = clock.now
        #expect(a <= b)
    }
}

@Suite("T-010 NovaKit identifiers")
struct IdentifierTests {
    @Test("monotonic ids only move forward")
    func monotonicIDs() {
        let e = Epoch.initial
        #expect(e.next() > e)
        #expect(e.next().next().value == 2)
        #expect(Generation.initial.next() == Generation(1))
    }

    @Test("F-09 call ids: 1...128 chars of [A-Za-z0-9_-]")
    func callIDValidation() {
        #expect(CallID("call_01-AbZ") != nil)
        #expect(CallID("") == nil)
        #expect(CallID("has space") == nil)
        #expect(CallID("中文") == nil)
        #expect(CallID(String(repeating: "a", count: 128)) != nil)
        #expect(CallID(String(repeating: "a", count: 129)) == nil)
    }
}

@Suite("T-010 NovaKit JSON and results")
struct JSONTests {
    @Test("JSON round-trips")
    func roundTrip() throws {
        let value: JSONValue = ["index": 1, "ratio": 0.5, "name": "珠海站", "ok": true, "none": nil, "list": [1, "a"]]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
        #expect(decoded["index"] == .int(1))
        #expect(decoded["index"]?.intValue == 1)
        #expect(decoded["name"]?.stringValue == "珠海站")
    }

    @Test("integral doubles round-trip as equal numbers")
    func integralDoubles() throws {
        let value: JSONValue = ["x": .double(2.0), "big": .double(1e3)]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded.hashValue == value.hashValue)
        #expect(JSONValue.int(2) != .double(2.5))
    }

    @Test("canonical encoder sorts keys")
    func canonicalBytes() throws {
        let value: JSONValue = ["b": 1, "a": ["d": 2, "c": 3]]
        let text = String(decoding: try JSONValue.canonicalEncoder().encode(value), as: UTF8.self)
        #expect(text == #"{"a":{"c":3,"d":2},"b":1}"#)
    }

    @Test("tool result helpers")
    func toolResult() {
        let ok = ToolResult.success(["power": true])
        #expect(ok.ok && ok.code == nil)
        let fail = ToolResult.failure(.unsupportedBodyPart, advice: "天窗不支持")
        #expect(!fail.ok && fail.code?.rawValue == "UNSUPPORTED_BODY_PART")
        #expect(ToolErrorCode.validationError.rawValue == "_validation_error")
    }
}

@Suite("T-010 NovaKit states and tuning")
struct StateTests {
    @Test("audio is uploaded only in ACTIVE and SILENT_WAIT; spoken only in ACTIVE")
    func listening() {
        #expect(ListeningState.allCases.filter(\.uploadsAudio) == [.active, .silentWait])
        #expect(ListeningState.allCases.filter(\.speaksReplies) == [.active])
    }

    @Test("navigation session active phases")
    func navPhases() {
        #expect(Set(NavigationPhase.allCases.filter(\.isSessionActive))
            == [.planningRoute, .calculatingRoute, .routeReady, .navigating])
    }

    @Test("tuning defaults equal the Android constants")
    func tuningDefaults() {
        let gate = UplinkGateTuning()
        #expect(gate.onset == .milliseconds(200) && gate.preRoll == .milliseconds(300) && gate.hangover == .milliseconds(1200))
        #expect(ReconnectTuning().maxAttempts == 5)
        #expect(AzureSpeechTuning().clauseDeadline(characters: 10) == .milliseconds(8000))
        #expect(ListeningLifecycleTuning().sleepToDeepIdle == .minutes(5))
    }
}

@Suite("T-010 typed diagnostics (I-7, I-8)")
struct DiagnosticsTests {
    static let samples: [DiagnosticEvent] = [
        .sessionState(.listening), .listeningState(.sleep), .navigationPhase(.navigating),
        .reconnectAttempt(attempt: 1, delay: .milliseconds(200)), .providerEventsDropped(count: 1),
        .setupTimeout, .toolRefused(code: .ambiguousReferent), .toolFailed(code: .vehicleExecutionFailed),
        .lateToolResultDropped(turn: .initial), .navLateResultDropped(stale: .initial, current: .initial.next()),
        .staleAudioDropped(stale: .initial, current: .initial.next()), .bargeIn(qualified: true),
        .claimHeld(events: 3), .correctionSent, .emptyResponseReask, .turnUnanswered(turn: 1),
        .stopPhrase(source: .kws, phrase: 0, msFromSpeechStart: 600, score: 80, selfStop: false), .stopPhraseMiss(utterance: 2), .timerFired(stale: false),
        .sessionError(.audioCaptureFailed), .networkLost, .networkRestored, .offlineRestoreAttempt,
        .resumed(handle: true), .offlineCapReached, .stopSyncSent, .stopSyncInterrupted(ms: 300), .stopSyncNoInterrupt,
        .reaskSuppressed, .abandonCleared,
    ]

    /// The case label as Swift reflects it (`.bargeIn(qualified:)` -> "bargeIn").
    static func caseLabel(_ event: DiagnosticEvent) -> String {
        Mirror(reflecting: event).children.first?.label ?? String(describing: event)
    }

    /// Walks every stored value, however deeply nested, and collects any text it finds.
    static func textValues(in value: Any) -> [Any] {
        if value is String || value is Substring || value is Character { return [value] }
        return Mirror(reflecting: value).children.flatMap { textValues(in: $0.value) }
    }

    @Test("every DiagnosticEvent case has a sample")
    func samplesCoverEveryCase() {
        #expect(Set(Self.samples.map(\.kind)) == Set(DiagnosticEvent.Kind.allCases))
    }

    @Test("each kind tag names its own case")
    func kindMatchesCase() {
        for event in Self.samples {
            #expect(event.kind.rawValue == Self.caseLabel(event))
        }
    }

    @Test("no diagnostic case carries a String payload, at any depth")
    func noStringPayloads() {
        for event in Self.samples {
            #expect(Self.textValues(in: event).isEmpty, "\(event.kind) carries text")
        }
    }

    @Test("the recursive walk finds nested text")
    func walkFindsNestedText() {
        struct Inner { let note: String }
        struct Outer { let inner: Inner; let count: Int }
        #expect(Self.textValues(in: Outer(inner: Inner(note: "x"), count: 1)).count == 1)
    }

    @Test("tool error codes are a closed set")
    func toolErrorCodesAreClosed() {
        #expect(ToolErrorCode(rawValue: "geocode failed: 1 Main St") == nil)
        #expect(ToolErrorCode.allCases.allSatisfy { !$0.rawValue.contains(" ") })
    }
}

@Suite("T-022a F-08 §14 item 7 log lines")
struct StopPhraseLogLineTests {
    @Test("stopPhrase and stopPhraseMiss lines carry numbers and the source only")
    func lines() {
        #expect(DiagnosticEvent.stopPhrase(source: .kws, phrase: 2, msFromSpeechStart: 640, score: 81, selfStop: false).logLine
                == "stopPhrase source=kws phrase=2 msFromSpeechStart=640 score=81 selfStop=false")
        #expect(DiagnosticEvent.stopPhraseMiss(utterance: 7).logLine == "stopPhraseMiss utterance=7")
        #expect(DiagnosticEvent.correctionSent.logLine == "diagnostic correctionSent")
    }
}
