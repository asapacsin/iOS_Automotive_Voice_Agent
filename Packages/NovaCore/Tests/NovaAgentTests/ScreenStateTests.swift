import Testing
@testable import NovaAgent
@testable import NovaKit

/// F-09b §16 (T-031z): the screen state from the views' reports, the `屏幕` line, and when it is sent.
@Suite("F-09b §16 screen state")
struct ScreenStateTests {
    static func lines(_ effects: [AgentEffect]) -> [String] {
        FlexibleAssistantTests.notes(effects).flatMap { $0.split(separator: "\n").map(String.init) }
            .filter { $0.hasPrefix("[系统] 屏幕：") }
    }

    @Test("T-031z row 1: a key follows the view's report only; a flow cancel without the view's off keeps it on")
    func row1() {
        var s = ScreenState()
        let opened = s.report(.destinationList, on: true)
        #expect(opened && s.isOn(.destinationList))
        let again = s.report(.destinationList, on: true)
        #expect(!again)  // a repeat is no change
        // The flow thinks it closed the list; nothing reports `off` from the view: still on.
        #expect(s.isOn(.destinationList) && !s.navigationOff)
        let closed = s.report(.destinationList, on: false)
        #expect(closed && !s.isOn(.destinationList) && s.navigationOff)
        let high = s.reportVolume(14)
        #expect(high && s.musicVolume == 10)
        let low = s.reportVolume(-2)
        #expect(low && s.musicVolume == 0)
        let heard = s.reportMusic(heard: true)
        #expect(heard && s.music)
    }

    @Test("T-031z row 2: the line has every key in the fixed order, on/off and a number only; the record line has codes only")
    func row2() {
        var s = ScreenState(musicVolume: 6)
        s.report(.routePicking, on: true)
        #expect(s.line == "[系统] 屏幕：destinationList off；routePicking on；routeCalculating off；navigation off；tripScreen off；tripDetail off；tripPlans off；musicCard off；music off；musicVolume 6；camera off；working off；settings off。这句不用回答。")
        #expect(s.recordLine == "screen destinationList=off routePicking=on routeCalculating=off navigation=off tripScreen=off tripDetail=off tripPlans=off musicCard=off music=off musicVolume=6 camera=off working=off settings=off")
        #expect(DiagnosticEvent.screenLine(s).logLine == s.recordLine)
    }

    @Test("T-031z row 3: sent on connect and on change; changes during her reply go as one line after it, the latest state")
    func row3() {
        var d = Drive()
        d.send(.start)
        var s = ScreenState()
        d.send(.screen(s))
        // Connect: one line.
        #expect(Self.lines(d.realtime(.setupComplete)).count == 1)
        // The same state again: nothing.
        #expect(Self.lines(d.send(.screen(s))).isEmpty)
        // A change while idle: one line.
        s.report(.destinationList, on: true)
        #expect(Self.lines(d.send(.screen(s))) == [s.line])
        // Two changes while her reply is open: nothing until it ends, then only the latest.
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.turn = d.turn.next()
        d.realtime(.responseStarted(d.turn))
        s.report(.destinationList, on: false)
        #expect(Self.lines(d.send(.screen(s))).isEmpty)
        s.report(.routePicking, on: true)
        #expect(Self.lines(d.send(.screen(s))).isEmpty)
        d.realtime(.replyText(d.turn, "好的。"))
        let done = d.realtime(.responseDone(d.turn, outcome: .completed))
        #expect(Self.lines(done) == [s.line])
        // A reconnect sends it again.
        #expect(Self.lines(d.realtime(.setupComplete)).count == 1)
    }
}
