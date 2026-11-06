import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaVoice

/// A spotter-shaped engine: the test plays keyword labels as the sherpa spotter would report them; `WakeHitFilter`
/// decides which are wakes, exactly as `SherpaWakeEngine` does.
final class LabelledWakeEngine: WakeEngine {
    private let handler = Mutex<(@Sendable (WakeEngineEvent) -> Void)?>(nil)
    private let filter = Mutex(WakeHitFilter())

    func start(onEvent: @escaping @Sendable (WakeEngineEvent) -> Void) async throws {
        filter.withLock { $0 = WakeHitFilter() }
        handler.withLock { $0 = onEvent }
    }

    func write(_ frame: PCMFrame16k) { filter.withLock { $0.frame() } }
    func stop() async { handler.withLock { $0 = nil } }

    /// The spotter reported `keyword`.
    func spotted(_ keyword: String) {
        guard filter.withLock({ $0.hit(keyword) }) else { return }
        handler.withLock { $0 }?(.detected)
    }
}

@Suite("T-060a F-01 §14 你好小诺 with no account or key")
struct WakeSherpaTests {
    // MARK: Phrase and keywords (items 2-3)

    @Test("F-01 §14 item 2: two token lines, exactly as the spec gives them, one phrase")
    func tokenLines() {
        #expect(WakePhrase.forms.map { $0.tokens.joined(separator: " ") } == [
            "n ǐ h ǎo x iǎo n uò", "n í h ǎo x iǎo n uò",
        ])
        #expect(WakePhrase.forms.allSatisfy { $0.text == WakePhrase.text })
        // Each token is an initial or a tone-marked final, like the stop phrases.
        for token in WakePhrase.forms.flatMap(\.tokens) where !StopPhrases.initials.contains(token) {
            #expect(token.unicodeScalars.contains { $0.value > 0x7F }, "\(token) has no tone mark")
        }
    }

    @Test("F-01 §14 item 3: keywords file carries the wake boost and threshold and labels each form")
    func keywordsFile() {
        let file = WakePhrase.keywordsFile(boost: 1.5, threshold: 0.3)
        #expect(file == "n ǐ h ǎo x iǎo n uò :1.5 #0.3 @wake0\nn í h ǎo x iǎo n uò :1.5 #0.3 @wake1\n")
        #expect(WakePhrase.form(ofKeyword: "wake0") == 0)
        #expect(WakePhrase.form(ofKeyword: "@wake1") == 1)
        #expect(WakePhrase.form(ofKeyword: "wake2") == nil)
        #expect(WakePhrase.form(ofKeyword: "0") == nil)  // a stop-phrase label is not a wake
        #expect(WakePhrase.form(ofKeyword: "") == nil)
    }

    // MARK: Row 2-3: when the listener takes the microphone

    private static var ready: WakeListenPolicy {
        var p = WakeListenPolicy()
        p.engine = .sherpa
        p.engineAvailable = true
        p.micGranted = true
        return p
    }

    @Test("F-01 §14 row 2: no iFlytek values, model loads, mic granted, foreground, no session, setting on: listens")
    func row2Listens() {
        let p = Self.ready
        #expect(!p.keysSaved)
        #expect(p.enabled)  // 「唤醒词」 is on by default
        #expect(WakeEngineKind.selected == .sherpa)
        #expect(WakeListenPolicy().engine == .sherpa)
        #expect(p.shouldListen)
    }

    @Test("F-01 §14 row 3: model fails, mic denied, background, session running, setting off: no listening, the button works")
    func row3NotListening() {
        var failed = Self.ready; failed.engineAvailable = false
        var gaveUp = Self.ready; gaveUp.gaveUp = true          // the model would not load: bounded retry gave up
        var denied = Self.ready; denied.micGranted = false
        var background = Self.ready; background.foreground = false
        var running = Self.ready; running.sessionRunning = true
        var off = Self.ready; off.enabled = false
        for p in [failed, gaveUp, denied, background, running, off] { #expect(!p.shouldListen) }
        // A finished session is the next chance: the listener is applied again.
        running.sessionRunning = false
        #expect(running.shouldListen)
        // The talk button still works when wake is unavailable.
        var arming = WakeArming()
        _ = arming.detector(.unavailable)
        #expect(arming.route == .none)
        #expect(arming.tap() == .startSession)
    }

    @Test("F-01 §14 row 3: the model failing to load ends in unavailable after the bounded retries")
    func row3ModelFailsBounded() async {
        let clock = ManualClock()
        let engine = ScriptedWakeEngine(failStarts: 100)
        let detector = RetryingWakeDetector(engine: engine, clock: clock)
        var it = detector.events.makeAsyncIterator()
        await detector.arm()
        for attempt in 1...6 {
            #expect(await it.next() == .failed(attempt: attempt))
            for _ in 0..<50 { await Task.yield() }
            clock.advance(by: .seconds(30))
            for _ in 0..<50 { await Task.yield() }
        }
        #expect(await it.next() == .unavailable)
    }

    @Test("F-01 §14 item 5: with sherpa selected the three 讯飞 fields are hidden")
    func iflytekFieldsHidden() {
        #expect(WakeEngineKind.sherpa.hiddenKeys == [.iflytekAppID, .iflytekAPIKey, .iflytekAPISecret])
        #expect(WakeEngineKind.iflytek.hiddenKeys.isEmpty)
        #expect(!WakeEngineKind.sherpa.needsKeys && WakeEngineKind.iflytek.needsKeys)
    }

    // MARK: Row 4: both forms, a duplicate, a late wake

    @Test("F-01 §14 row 4: each phrase form is one wake; the duplicate and the wake after disarm start nothing")
    func row4Forms() async {
        let engine = LabelledWakeEngine()
        let detector = RetryingWakeDetector(engine: engine, clock: ManualClock())
        var it = detector.events.makeAsyncIterator()
        var arming = WakeArming()
        var starts = 0
        func decide(_ event: WakeEvent) { if arming.detector(event) != .ignore { starts += 1 } }

        await detector.arm()
        #expect(await it.next() == .ready)
        decide(.ready)

        // ní hǎo form: one wake, one session start.
        engine.spotted("wake1")
        #expect(await it.next() == .wake)
        decide(.wake)
        #expect(starts == 1)
        // The other form on the same words: dropped by the filter.
        detector.feed(.silence)
        engine.spotted("wake0")
        // A duplicate callback that got through anyway starts nothing (WakeArming).
        decide(.wake)
        #expect(starts == 1)
        // Session ran and ended; the lifecycle is idle again.
        arming.lifecycle(.active)
        arming.lifecycle(.deepIdle)

        // nǐ hǎo form, well after: one wake, one start.
        for _ in 0..<WakeHitFilter.refractoryFrames { detector.feed(.silence) }
        engine.spotted("wake0")
        #expect(await it.next() == .wake)
        decide(.wake)
        #expect(starts == 2)

        // Late wake after disarm: dropped by the detector.
        await detector.disarm()
        for _ in 0..<WakeHitFilter.refractoryFrames { engine.write(.silence) }
        engine.spotted("wake1")
        detector.feed(.silence)
        await detector.arm()
        #expect(await it.next() == .ready)  // the next event is the re-arm, not a wake
        #expect(starts == 2)
    }

    @Test("F-01 §14 item 2: the hit filter drops the second form inside 1.5 s and non-wake labels")
    func hitFilter() {
        var f = WakeHitFilter()
        let r1 = f.hit("wake1")
        #expect(r1)
        for _ in 0..<(WakeHitFilter.refractoryFrames - 1) { f.frame() }
        let r2 = f.hit("wake0")
        #expect(!r2)
        f.frame()
        let r3 = f.hit("wake0")
        #expect(r3)
        let r4 = f.hit("3")
        #expect(!r4)
    }

    // MARK: Row 5: the screen stays on while listening

    @Test("F-01 §14 row 5: listener start disables the idle timer; stop restores the value from before")
    func row5IdleTimer() {
        var hold = IdleTimerHold()
        var idleTimerDisabled = false
        idleTimerDisabled = hold.hold(current: idleTimerDisabled)
        #expect(idleTimerDisabled && hold.holding)
        // A second start while held keeps the original value.
        idleTimerDisabled = hold.hold(current: idleTimerDisabled)
        if let restore = hold.release() { idleTimerDisabled = restore }
        #expect(!idleTimerDisabled && !hold.holding)
        let r5 = hold.release()
        #expect(r5 == nil)  // nothing held: nothing changes
        // Something else had it on already: it stays on after the listener stops.
        idleTimerDisabled = true
        idleTimerDisabled = hold.hold(current: idleTimerDisabled)
        let r6 = hold.release()
        #expect(r6 == true)
    }

    // MARK: Row 6: startedBy and the sound

    @Test("F-01 §14 row 6: woken session plays the sound once on the first listening, not after a reconnect")
    func row6WakeCue() {
        var s = WakeSessionStart(origin: .wake(at: NovaInstant(milliseconds: 1_000)))
        #expect(s.origin.startedBy == "wake")
        let r7 = s.sessionState(.connecting, at: NovaInstant(milliseconds: 1_100))
        #expect(r7.isEmpty)
        let r8 = s.sessionState(.listening, at: NovaInstant(milliseconds: 3_200))
        #expect(r8 == [.wakeToListening(ms: 2_200), .playCue])
        let r9 = s.sessionState(.speaking, at: NovaInstant(milliseconds: 5_000))
        #expect(r9.isEmpty)
        let r10 = s.sessionState(.listening, at: NovaInstant(milliseconds: 6_000))
        #expect(r10.isEmpty)
        let r11 = s.sessionState(.reconnecting, at: NovaInstant(milliseconds: 7_000))
        #expect(r11.isEmpty)
        let r12 = s.sessionState(.listening, at: NovaInstant(milliseconds: 8_000))
        #expect(r12.isEmpty)  // after a reconnect
    }

    @Test("F-01 §14 row 6: a tapped session has startedBy tap and no sound")
    func row6Tap() {
        var s = WakeSessionStart(origin: .tap)
        #expect(s.origin.startedBy == "tap")
        let r13 = s.sessionState(.listening, at: NovaInstant(milliseconds: 500))
        #expect(r13.isEmpty)
        let r14 = s.end()
        #expect(!r14)  // a tap is never wake-unused
    }

    @Test("F-01 §14 row 6: the shared watch reads its clock for wake-to-listening")
    func row6Watch() {
        let clock = ManualClock()
        let watch = WakeSessionWatch(origin: .wake(at: clock.now), clock: clock)
        #expect(watch.startedBy == "wake")
        clock.advance(by: .milliseconds(1_800))
        #expect(watch.sessionState(.listening) == [.wakeToListening(ms: 1_800), .playCue])
        #expect(watch.sessionState(.listening).isEmpty)
    }

    // MARK: Row 7: the sound is not the driver

    /// The cue as the microphone would hear it with no echo cancellation at all, in 10 ms frames.
    private static func cueFrames() -> [PCMFrame16k] {
        let samples = WakeCue.samples(rate: PCMFrame16k.sampleRate)
        let padded = samples + Array(repeating: 0, count: (160 - samples.count % 160) % 160)
        return stride(from: 0, to: padded.count, by: 160).map { PCMFrame16k(samples: Array(padded[$0..<($0 + 160)]))! }
    }

    private static func warmGate() -> SpeechUplinkGate {
        var gate = SpeechUplinkGate()
        gate.suppressionEnabled = false  // F-04 rules alone: the strictest case for the cue
        for _ in 0..<200 { _ = gate.process(.silence) }
        return gate
    }

    @Test("F-01 §14 row 7: the sound heard back unfiltered opens no utterance")
    func row7NoUtterance() {
        #expect(WakeCue.parts.allSatisfy { $0.hz == 0 || $0.ms < 200 })  // each tone shorter than the gate's onset
        var gate = Self.warmGate()
        var outputs: [UplinkGateOutput] = []
        for frame in Self.cueFrames() + Array(repeating: .silence, count: 150) { outputs += gate.process(frame) }
        #expect(!outputs.contains { if case .speechStarted = $0 { true } else { false } })
        #expect(gate.phase == .closed)
        // Control: one tone as long as the whole cue, at the same level, does open the gate.
        var control = Self.warmGate()
        let tone = WakeCue.samples(rate: 16_000).count / 160
        var opened = false
        for f in 0..<(tone + 30) {
            let frame = PCMFrame16k(samples: (0..<160).map { i in
                Int16((WakeCue.level * 32_767 * sinTaylor(2 * .pi * 880 * Double(f * 160 + i) / 16_000)).rounded())
            })!
            if control.process(frame).contains(where: { if case .speechStarted = $0 { true } else { false } }) { opened = true }
        }
        #expect(opened)
    }

    @Test("F-01 §14 row 7: during her reply the sound stops nothing: the gate stays as it was")
    func row7NoReplyStop() {
        var gate = Self.warmGate()
        gate.setPlaying(reply: true)
        var outputs: [UplinkGateOutput] = []
        for frame in Self.cueFrames() { outputs += gate.process(frame) }
        #expect(outputs.allSatisfy { if case .speechStarted = $0 { false } else { true } })
        #expect(gate.replyPlaying)
        // The cue is its own effect; nothing in it flushes or opens anything.
        var s = WakeSessionStart(origin: .wake(at: .zero))
        let effects = s.sessionState(.listening, at: NovaInstant(milliseconds: 10))
        #expect(effects.filter { $0 == .playCue }.count == 1)
        #expect(WakeCue.pcm.sampleRate == PCMBuffer.replySampleRate)
        #expect(WakeCue.pcm.duration < .milliseconds(400))
    }

    // MARK: Row 8: a wake with no words

    @Test("F-01 §14 row 8: woken session with no utterance sent is wake-unused once")
    func row8WakeUnused() {
        var s = WakeSessionStart(origin: .wake(at: .zero))
        _ = s.sessionState(.listening, at: NovaInstant(milliseconds: 2_000))
        s.speechStarted(sentToModel: false)  // a muted utterance is not one sent
        let r15 = s.end()
        #expect(r15)
        let r16 = s.end()
        #expect(!r16)  // once

        var spoken = WakeSessionStart(origin: .wake(at: .zero))
        spoken.speechStarted(sentToModel: true)  // before the sound: not kept, does not count
        _ = spoken.sessionState(.listening, at: NovaInstant(milliseconds: 2_000))
        var copy = spoken
        let r17 = copy.end()
        #expect(r17)
        spoken.speechStarted(sentToModel: true)
        let r18 = spoken.end()
        #expect(!r18)
    }

    // MARK: Item 8: the hint

    @Test("F-01 §14 item 8: the hint shows only while armed with no session")
    func hint() {
        #expect(WakePhrase.hint(armed: true, sessionRunning: false) == "说“你好小诺”唤醒")
        #expect(WakePhrase.hint(armed: false, sessionRunning: false) == nil)
        #expect(WakePhrase.hint(armed: true, sessionRunning: true) == nil)
    }
}

private func sinTaylor(_ x: Double) -> Double {
    var x = x.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    var term = x, sum = x
    for n in stride(from: 3, through: 21, by: 2) {
        term *= -x * x / Double((n - 1) * n)
        sum += term
    }
    return sum
}
