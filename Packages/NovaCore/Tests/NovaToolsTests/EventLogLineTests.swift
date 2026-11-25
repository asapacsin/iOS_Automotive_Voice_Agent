import Testing
@testable import NovaTools

@Suite("T-046zf/zg I-8 events lines in the system log")
struct EventLogLineTests {
    @Test("T-046zf F-18 §43 item 3 with I-8: name-bearing events lines stay out of the system log; q= is cut; counts stay")
    func logLines() {
        #expect(EventLogLine.forLog("events drop name=2026横琴AI嘉年华 reason=past") == nil)
        #expect(EventLogLine.forLog("events image name=x via=og") == nil)
        #expect(EventLogLine.forLog("events check name=x venue=page dates=result image=og") == nil)
        #expect(EventLogLine.forLog("events fill name=x found=no") == nil)
        #expect(EventLogLine.forLog("events query 1/3 ms=2400 ok=yes sources=20 searches=1 tokens=0 q=AIE 珠海 澳门 2026年11月")
                == "events query 1/3 ms=2400 ok=yes sources=20 searches=1 tokens=0")
        #expect(EventLogLine.forLog("events search done ms=30000 queries=3 failed=0 kept=3 dropped=1 tokens=16500")
                == "events search done ms=30000 queries=3 failed=0 kept=3 dropped=1 tokens=16500")
    }
}
