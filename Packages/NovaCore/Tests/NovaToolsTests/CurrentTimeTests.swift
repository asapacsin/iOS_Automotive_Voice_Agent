import Foundation
import Testing
@testable import NovaKit
@testable import NovaTools

@Suite("T-046b F-18 §14 current time from the phone clock")
struct CurrentTimeTests {
    /// 2026-10-31 12:08:30 UTC.
    let instant = Date(timeIntervalSince1970: 1_793_448_510)

    func field(_ r: ToolResult, _ key: String) -> String? { r.data[key]?.stringValue }

    @Test("Row 1: Shanghai: 20:08 晚上 2026年10月31日 星期六 +08:00")
    func shanghai() throws {
        let r = CurrentTime.result(now: instant, zone: try #require(TimeZone(identifier: "Asia/Shanghai")))
        #expect(r.ok)
        #expect(field(r, "time") == "20:08")
        #expect(field(r, "period") == "晚上")
        #expect(field(r, "date") == "2026年10月31日")
        #expect(field(r, "weekday") == "星期六")
        #expect(field(r, "timeZone") == "Asia/Shanghai")
        #expect(field(r, "utcOffset") == "+08:00")
        #expect(field(r, "next")?.hasPrefix("只按 time 和 date 回答") == true)
    }

    @Test("Row 2: London 12:08 中午 +00:00; New York 08:08 早上 -04:00; the date follows the zone")
    func otherZones() throws {
        let london = CurrentTime.result(now: instant, zone: try #require(TimeZone(identifier: "Europe/London")))
        #expect(field(london, "time") == "12:08" && field(london, "period") == "中午" && field(london, "utcOffset") == "+00:00")
        let ny = CurrentTime.result(now: instant, zone: try #require(TimeZone(identifier: "America/New_York")))
        #expect(field(ny, "time") == "08:08" && field(ny, "period") == "早上" && field(ny, "utcOffset") == "-04:00")
        let tokyoLate = CurrentTime.result(now: instant.addingTimeInterval(3 * 3600),
                                           zone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        #expect(field(tokyoLate, "date") == "2026年11月1日" && field(tokyoLate, "weekday") == "星期日")
    }

    @Test("Row 3: 23:59:59 then 00:00:01 in Shanghai: new date and weekday (no caching)")
    func midnight() async throws {
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        // 2026-10-31 23:59:59 +08:00 = 15:59:59 UTC.
        let before = Date(timeIntervalSince1970: 1_793_462_399)
        let clock = Mutable(before)
        let executor = CurrentTimeProbe(now: { clock.value }, zone: zone)
        let a = executor.call()
        clock.value = before.addingTimeInterval(2)
        let b = executor.call()
        #expect(field(a, "date") == "2026年10月31日" && field(a, "weekday") == "星期六" && field(a, "time") == "23:59")
        #expect(field(b, "date") == "2026年11月1日" && field(b, "weekday") == "星期日" && field(b, "time") == "00:00")
        #expect(field(b, "period") == "凌晨")
    }

    @Test("Row 4: whatever the phone's language, clock or calendar: 24-hour, Gregorian, Chinese")
    func phoneSettingsIgnored() throws {
        // The result never reads Locale or Calendar.current; Gregorian is set explicitly.
        let zone = try #require(TimeZone(identifier: "Asia/Bangkok"))
        let r = CurrentTime.result(now: instant, zone: zone)
        #expect(field(r, "time") == "19:08")
        #expect(field(r, "date") == "2026年10月31日")  // not Buddhist year 2569
        #expect(field(r, "weekday") == "星期六")
        #expect(field(r, "time")?.contains("PM") == false)
    }

    @Test("Row 5: an unknown extra argument is INVALID_ARGUMENT")
    func extraArgument() {
        let r = CurrentTime.result(now: instant, zone: TimeZone(secondsFromGMT: 0)!,
                                   arguments: ["kind": "current_time", "where": "here"])
        #expect(!r.ok && r.code == .invalidArgument)
    }

    @Test("Row 6: catalog: current_time in the kind enum and the description; validation accepts it")
    func catalog() throws {
        #expect(ToolCatalog.liveInfoKinds.contains("current_time"))
        let spec = try #require(ToolCatalog.specs.first { $0.declaration.name == "query_live_info" })
        #expect(spec.declaration.description.contains("current_time：「现在几点」「今天几号」「今天星期几」「现在是上午还是下午」，只按返回结果回答，绝不自己猜时间"))
        guard case .array(let kinds)? = spec.declaration.parametersJSONSchema["properties"]?["kind"]?["enum"] else {
            Issue.record("no kind enum")
            return
        }
        #expect(kinds.contains(.string("current_time")))
    }

    @Test("Periods: boundaries per item 2")
    func periods() {
        #expect([0, 4, 5, 7, 8, 9, 11, 12, 13, 17, 18, 23].map(CurrentTime.period)
                == ["凌晨", "凌晨", "早上", "早上", "早上", "上午", "中午", "中午", "下午", "下午", "晚上", "晚上"])
    }
}

private final class Mutable: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private struct CurrentTimeProbe {
    let now: @Sendable () -> Date
    let zone: TimeZone
    func call() -> ToolResult { CurrentTime.result(now: now(), zone: zone) }
}
