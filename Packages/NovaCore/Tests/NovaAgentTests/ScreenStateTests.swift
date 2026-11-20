import Foundation
import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaPorts

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
        #expect(s.line == "[系统] 屏幕：destinationList off；routePicking on；routeCalculating off；navigation off；tripScreen off；tripDetail off；tripPlans off；musicCard off；music off；musicVolume 6；camera off；working off；settings off；top routePicking。这句不用回答。")
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

    // MARK: F-09b §17 (T-031zb)

    @Test("T-031zb row 3 / item 2: top = highest layer, then newest; layer 1 never over layer 2; none when nothing layered")
    func stackTop() {
        var s = ScreenState()
        #expect(s.top == nil)
        s.report(.working, on: true)
        #expect(s.top == nil)
        s.report(.navigation, on: true)
        #expect(s.top == .navigation)
        s.report(.destinationList, on: true)
        s.report(.musicCard, on: true)
        #expect(s.top == .destinationList)  // the newer music card is layer 1, the list layer 2
        s.report(.tripDetail, on: true)
        #expect(s.top == .tripDetail)
        s.report(.tripDetail, on: false)
        s.report(.camera, on: true)
        #expect(s.top == .camera)  // same layer as the list, newer
        s.report(.camera, on: false)
        s.report(.destinationList, on: false)
        #expect(s.top == .musicCard)
        #expect(ScreenPanel.working.layer == nil && ScreenPanel.settings.layer == nil)
        #expect(ScreenPanel.allCases.allSatisfy { $0.layer == nil || PanelRegistry.entry($0).close == "exit_navigation_mode" })
    }

    @Test("T-031zb row 8 / item 7: a panel line per report with the top after it")
    func row8() {
        var s = ScreenState()
        s.report(.destinationList, on: true)
        #expect(s.panelLine(.destinationList, on: true) == "panel destinationList on top=destinationList")
        s.report(.tripDetail, on: true)
        #expect(s.panelLine(.tripDetail, on: true) == "panel tripDetail on top=tripDetail")
        s.report(.tripDetail, on: false)
        s.report(.destinationList, on: false)
        #expect(s.panelLine(.destinationList, on: false) == "panel destinationList off top=none")
        var r = ConversationRecorder()
        #expect(r.add(.panel(.tripDetail, on: false, after: ScreenState(on: [.destinationList])), atMs: 5)
                == ["5 panel tripDetail off top=destinationList"])
    }

    @Test("T-031zb row 8: the store calls onReport at each changing report, in order")
    func storeReports() async {
        let store = ScreenStateStore()
        let seen = ReportLines()
        await store.onReport { panel, on, after in seen.add(after.panelLine(panel, on: on)) }
        await store.report(.destinationList, on: true)
        await store.report(.destinationList, on: true)  // no change: no line
        await store.report(.tripDetail, on: true)
        await store.report(.tripDetail, on: false)
        #expect(seen.all == ["panel destinationList on top=destinationList", "panel tripDetail on top=tripDetail",
                             "panel tripDetail off top=destinationList"])
    }

    @Test("T-031zb row 7 / item 6: list and card open while the driver keeps talking: the next driver turn and the next tool result carry the latest line")
    func row7() {
        var d = Drive()
        d.send(.start)
        var s = ScreenState()
        d.send(.screen(s))
        d.realtime(.setupComplete)
        // The driver talks; the list and the card open meanwhile (no idle moment).
        d.send(.speechStarted(recentSpeech: true))
        s.report(.destinationList, on: true)
        d.send(.screen(s))
        s.report(.tripDetail, on: true)
        #expect(Self.lines(d.send(.screen(s))).isEmpty)
        d.send(.speechStopped)
        // The next driver turn: the owed line goes ahead of it, with top tripDetail.
        let next = d.send(.speechStarted(recentSpeech: true))
        #expect(Self.lines(next) == [s.line])
        #expect(s.line.hasSuffix("top tripDetail。这句不用回答。"))
        d.send(.speechStopped)
        // A change, then a tool result before any idle moment: the result carries it as `screen`.
        s.report(.tripDetail, on: false)
        d.send(.screen(s))
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        d.realtime(.toolCalls(t1, [climateOn()]))
        let done = d.send(.toolFinished(t1, climateOn(), .success(["power_on": true])))
        let sent = done.compactMap { e -> ToolResponse? in
            if case .provider(.toolResponses(let r)) = e { r.first } else { nil }
        }
        #expect(sent.first?.result.data["screen"] == .string(s.line))
        // Sent once: the idle path has nothing more to send.
        #expect(Self.lines(d.realtime(.responseDone(t1, outcome: .completed))).isEmpty)
    }
}

final class ReportLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
