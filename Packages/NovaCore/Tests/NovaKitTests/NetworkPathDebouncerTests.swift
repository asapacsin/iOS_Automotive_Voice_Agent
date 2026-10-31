import NovaKit
import Testing

@Suite("T-016h F-24 §14 network path debounce")
struct NetworkPathDebouncerTests {
    @Test("F-24 §14 row 7: unsatisfied for 300 ms then satisfied: nothing reported")
    func blip() {
        var d = NetworkPathDebouncer()
        let (report, tick) = d.path(satisfied: false, at: .zero)
        #expect(report == nil && tick == NovaInstant(milliseconds: 500))
        #expect(d.path(satisfied: true, at: NovaInstant(milliseconds: 300)).report == nil)
        #expect(d.tick(at: NovaInstant(milliseconds: 500)) == nil)
        #expect(d.available)
    }

    @Test("F-24 §14 item 1: unsatisfied past 500 ms is lost; satisfied again is restored at once")
    func lostThenRestored() {
        var d = NetworkPathDebouncer()
        _ = d.path(satisfied: false, at: .zero)
        #expect(d.tick(at: NovaInstant(milliseconds: 499)) == nil)
        #expect(d.tick(at: NovaInstant(milliseconds: 500)) == false)
        #expect(d.path(satisfied: false, at: NovaInstant(milliseconds: 900)).report == nil)
        #expect(d.path(satisfied: true, at: NovaInstant(milliseconds: 2_000)).report == true)
    }
}
