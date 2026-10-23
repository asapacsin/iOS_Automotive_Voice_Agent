import Testing
@testable import NovaKit
@testable import NovaVoice

/// Drives a lifecycle with a fake shell: it keeps the one scheduled timer and fires it when time
/// reaches it, as `TimerService` will.
struct LifecycleHarness {
    var lifecycle = ListeningLifecycle()
    var now = NovaInstant.zero
    var scheduled: (LifecycleTimer, NovaInstant)?
    var log: [LifecycleEffect] = []

    @discardableResult
    mutating func send(_ input: LifecycleInput) -> [LifecycleEffect] {
        let effects = lifecycle.handle(input, at: now)
        apply(effects)
        return effects
    }

    mutating func advance(by duration: NovaDuration) {
        let target = now + duration
        while let (timer, at) = scheduled, at <= target {
            now = at
            scheduled = nil
            apply(lifecycle.handle(.timerFired(timer), at: now))
        }
        now = target
    }

    private mutating func apply(_ effects: [LifecycleEffect]) {
        log += effects
        for effect in effects {
            switch effect {
            case .schedule(let timer, let at): scheduled = (timer, at)
            case .cancelTimer: scheduled = nil
            default: break
            }
        }
    }

    var uploads: Bool { lifecycle.state.uploadsAudio }
}

@Suite("T-012 F-02 listening lifecycle")
struct ListeningLifecycleTests {
    func active() -> LifecycleHarness {
        var h = LifecycleHarness()
        h.send(.wake)
        return h
    }

    @Test("F-02 wake from DEEP_IDLE connects and goes ACTIVE")
    func wakeConnects() {
        var h = LifecycleHarness()
        let effects = h.send(.wake)
        #expect(effects.first == .connect)
        #expect(h.lifecycle.state == .active)
    }

    @Test("F-02 ACTIVE and idle for 30 s goes to SLEEP and stops uploading")
    func activeIdleSleeps() {
        var h = active()
        h.advance(by: .milliseconds(29_999))
        #expect(h.lifecycle.state == .active)
        h.advance(by: .milliseconds(1))
        #expect(h.lifecycle.state == .sleep)
        #expect(!h.uploads)
        #expect(!h.log.contains(.disconnect))
    }

    @Test("F-02 noise does not extend the idle timer; real speech does")
    func noiseDoesNotExtend() {
        var h = active()
        h.advance(by: .seconds(20))
        h.send(.noise)
        h.advance(by: .seconds(10))
        #expect(h.lifecycle.state == .sleep)

        var g = active()
        g.advance(by: .seconds(20))
        g.send(.utterance(.passToModel))
        g.advance(by: .seconds(29))
        #expect(g.lifecycle.state == .active)
        g.advance(by: .seconds(1))
        #expect(g.lifecycle.state == .sleep)
    }

    @Test("F-02 a deadline that passes while busy fires 1.5 s after becoming idle")
    func busyGrace() {
        var h = active()
        h.advance(by: .seconds(10))
        h.send(.busy(true))
        h.advance(by: .seconds(60))
        #expect(h.lifecycle.state == .active)
        h.send(.busy(false))
        h.advance(by: .milliseconds(1499))
        #expect(h.lifecycle.state == .active)
        h.advance(by: .milliseconds(1))
        #expect(h.lifecycle.state == .sleep)
    }

    @Test("F-02 a deadline not yet due when busy ends keeps its time")
    func busyBeforeDeadline() {
        var h = active()
        h.send(.busy(true))
        h.advance(by: .seconds(5))
        h.send(.busy(false))
        h.advance(by: .seconds(25))
        #expect(h.lifecycle.state == .sleep)
    }

    @Test("F-02 SLEEP for 5 min disconnects to DEEP_IDLE")
    func sleepDisconnects() {
        var h = active()
        h.send(.utterance(.goToSleep))
        h.advance(by: .minutes(5))
        #expect(h.lifecycle.state == .deepIdle)
        #expect(h.log.last == .disconnect)
    }

    @Test("F-02 SLEEP while navigating for 5 min keeps the connection open")
    func navigatingKeepsConnection() {
        var h = active()
        h.send(.navigating(true))
        h.send(.utterance(.goToSleep))
        h.advance(by: .minutes(30))
        #expect(h.lifecycle.state == .sleep)
        #expect(!h.log.contains(.disconnect))
        // Navigation ends: the overdue deadline fires after the grace period.
        h.send(.navigating(false))
        h.advance(by: .milliseconds(1500))
        #expect(h.lifecycle.state == .deepIdle)
        #expect(h.log.contains(.disconnect))
    }

    @Test("F-02 闭嘴 in ACTIVE stops speech, enters SILENT_WAIT, makes no tool call")
    func shutUp() {
        var h = active()
        let intent = ListeningIntent.classify("闭嘴！")
        #expect(intent == .shutUp)
        let effects = h.send(.utterance(intent))
        #expect(effects.first == .stopSpeaking)
        #expect(effects.contains(.stateChanged(.silentWait)))
        #expect(h.lifecycle.state == .silentWait)
        // Still listening, not speaking.
        #expect(h.uploads)
        #expect(!h.lifecycle.state.speaksReplies)
        // The lifecycle has no tool effect at all; the intent never reaches the model.
        #expect(intent != .passToModel)
    }

    @Test("F-02 SILENT_WAIT resumes on a real command, sleeps after 20 s without one")
    func silentWait() {
        var h = active()
        h.send(.utterance(.shutUp))
        h.send(.noise)
        h.advance(by: .seconds(19))
        h.send(.utterance(.passToModel))
        #expect(h.lifecycle.state == .active)

        var g = active()
        g.send(.utterance(.shutUp))
        g.advance(by: .seconds(20))
        #expect(g.lifecycle.state == .sleep)
    }

    @Test("F-02 休眠, 停止监听 and end_conversation sleep without disconnecting")
    func sleepRequests() {
        for input in [LifecycleInput.utterance(.goToSleep), .endConversation] {
            var h = active()
            h.send(input)
            #expect(h.lifecycle.state == .sleep)
            #expect(!h.log.contains(.disconnect))
        }
        #expect(ListeningIntent.classify("休眠") == .goToSleep)
        #expect(ListeningIntent.classify("停止监听。") == .goToSleep)
    }

    @Test("F-02 wake from SLEEP keeps the connection")
    func wakeFromSleep() {
        var h = active()
        h.send(.utterance(.goToSleep))
        let effects = h.send(.wake)
        #expect(!effects.contains(.connect))
        #expect(h.lifecycle.state == .active)
    }

    @Test("F-02 speech while asleep is ignored")
    func asleepIgnoresSpeech() {
        var h = active()
        h.send(.utterance(.goToSleep))
        #expect(h.send(.utterance(.passToModel)).isEmpty)
        #expect(h.lifecycle.state == .sleep)
    }

    @Test("F-02 a stale timer token is ignored")
    func staleTimer() {
        var h = active()
        guard case .schedule(let old, _)? = h.log.last else { Issue.record("no timer"); return }
        h.send(.utterance(.passToModel))
        #expect(h.lifecycle.handle(.timerFired(old), at: h.now + .minutes(10)).isEmpty)
        #expect(h.lifecycle.state == .active)
    }
}

@Suite("T-012 F-02 local intents")
struct ListeningIntentTests {
    @Test("F-02 with a picker open, 算了 reaches the model")
    func cancelWithPicker() {
        let picker = ListeningIntent.Context(pickerOpen: true)
        #expect(ListeningIntent.classify("算了", context: picker) == .passToModel)
        #expect(ListeningIntent.classify("取消", context: picker) == .passToModel)
    }

    @Test("F-02 算了 and 取消 are never intercepted")
    func cancelNeverIntercepted() {
        for text in ["算了", "取消", "算了。", " 取消！"] {
            #expect(ListeningIntent.classify(text) == .passToModel)
        }
    }

    @Test("F-02 only a whole utterance matches")
    func wholeUtterance() {
        #expect(ListeningIntent.classify("闭嘴吧") == .shutUp)
        #expect(ListeningIntent.classify("闭嘴，我想问个问题") == .passToModel)
        #expect(ListeningIntent.classify("你先休眠一下再导航") == .passToModel)
        #expect(ListeningIntent.classify("") == .passToModel)
    }

    @Test("F-02 sleep phrases reach the model while a picker is open or a task pends")
    func sleepWhileBusy() {
        #expect(ListeningIntent.classify("休眠", context: .init(pickerOpen: true)) == .passToModel)
        #expect(ListeningIntent.classify("停止监听", context: .init(taskPending: true)) == .passToModel)
        #expect(ListeningIntent.classify("闭嘴", context: .init(pickerOpen: true)) == .shutUp)
    }
}
