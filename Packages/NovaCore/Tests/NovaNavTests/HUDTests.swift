import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts

func info(icon: Int = 2, step: Int = 300, road: String? = "东风路", remaining: Int = 8_600, seconds: Int = 720,
          speed: Int? = nil, facility: Int = 0) -> NaviInfo {
    NaviInfo(iconType: icon, stepDistanceMeters: step, nextRoadName: road, remainingMeters: remaining,
             remainingSeconds: seconds, currentSpeedKmh: speed, facilityLimitKmh: facility)
}

@Suite("T-045 F-17 HUD panel model")
struct HUDPanelModelTests {
    @Test("F-17 §10 panel text for a navigation-info fixture")
    func fixturePanel() {
        let panel = HUDPanelModel(destinationName: "天安门", naviInfo: info(), lastGuidance: "前方左转", speedLimitKmh: 60)
        #expect(panel.title == "导航中 → 天安门")
        #expect(panel.turn == TurnIndicator(word: "左转", arrow: "←"))
        #expect(panel.stepDistanceText == "300 米")
        #expect(panel.nextRoadText == "进入 东风路")
        #expect(panel.remainingText == "剩余 8.6 km · 12 分钟")
        #expect(panel.speedLimitText == "限速 60 km/h")
        #expect(panel.lastGuidance == "前方左转")
        #expect(panel.statusText == nil)
    }

    @Test("F-17 waiting text before the first update")
    func waiting() {
        let panel = HUDPanelModel(destinationName: "天安门", naviInfo: nil)
        #expect(panel.statusText == "等待导航数据…")
        #expect(panel.turn == nil)
        #expect(panel.remainingText == nil)
    }

    @Test("F-17 §8 missing or blank road name omits 进入")
    func missingRoad() {
        #expect(HUDPanelModel(destinationName: "A", naviInfo: info(road: nil)).nextRoadText == nil)
        #expect(HUDPanelModel(destinationName: "A", naviInfo: info(road: "  ")).nextRoadText == nil)
    }

    @Test("F-17 §8 limit 0 hides the speed limit")
    func limitZero() {
        #expect(HUDPanelModel(destinationName: "A", naviInfo: info(), speedLimitKmh: 0).speedLimitText == nil)
    }

    @Test("F-17 step distance switches to 公里 at 1 000 m")
    func stepDistance() {
        #expect(HUDPanelModel.stepDistance(999) == "999 米")
        #expect(HUDPanelModel.stepDistance(1_000) == "1.0 公里")
        #expect(HUDPanelModel.stepDistance(2_460) == "2.5 公里")
    }

    @Test("F-17 turn table (PROPOSED); an unknown icon type invents no manoeuvre")
    func turnTable() {
        #expect(TurnIndicator.forIconType(3)?.word == "右转")
        #expect(TurnIndicator.forIconType(8)?.word == "掉头")
        #expect(TurnIndicator.forIconType(9)?.word == "直行")
        #expect(TurnIndicator.forIconType(0) == nil)
        #expect(TurnIndicator.forIconType(99) == nil)
        let panel = HUDPanelModel(destinationName: "A", naviInfo: info(icon: 0))
        #expect(panel.turn == nil)
        #expect(panel.stepDistanceText == "300 米")
        #expect(panel.nextRoadText == "进入 东风路")
    }
}

@Suite("T-053 F-17 overspeed monitor")
struct OverspeedMonitorTests {
    let clock = ManualClock()

    @Test("F-17 §10 fires once per exceedance")
    func oncePerExceedance() {
        var monitor = OverspeedMonitor(clock: clock)
        monitor.observe(cameras: [CameraInfo(distanceMeters: 200, speedLimitKmh: 60)])
        #expect(monitor.observe(info(speed: 70)) == "您已超速，限速60公里")
        clock.advance(by: .seconds(30))
        #expect(monitor.observe(info(speed: 75)) == nil)
    }

    @Test("F-17 §10 limit 0 never alerts")
    func limitZeroNeverAlerts() {
        var monitor = OverspeedMonitor(clock: clock)
        monitor.observe(cameras: [CameraInfo(distanceMeters: 100, speedLimitKmh: 0)])
        #expect(monitor.limitKmh == 0)
        #expect(monitor.observe(info(speed: 200)) == nil)
    }

    @Test("F-17 §10 back under the limit re-arms, but only after the 10 s gap")
    func rearmWithGap() {
        var monitor = OverspeedMonitor(clock: clock)
        monitor.observe(cameras: [CameraInfo(distanceMeters: 100, speedLimitKmh: 60)])
        #expect(monitor.observe(info(speed: 70)) != nil)
        #expect(monitor.observe(info(speed: 50)) == nil)
        clock.advance(by: .milliseconds(9_999))
        #expect(monitor.observe(info(speed: 70)) == nil)
        clock.advance(by: .milliseconds(1))
        #expect(monitor.observe(info(speed: 70)) == "您已超速，限速60公里")
    }

    @Test("F-17 limit change re-alerts while still over")
    func limitChange() {
        var monitor = OverspeedMonitor(clock: clock)
        monitor.observe(cameras: [CameraInfo(distanceMeters: 100, speedLimitKmh: 80)])
        #expect(monitor.observe(info(speed: 90)) == "您已超速，限速80公里")
        monitor.observe(cameras: [CameraInfo(distanceMeters: 50, speedLimitKmh: 60)])
        clock.advance(by: .seconds(10))
        #expect(monitor.observe(info(speed: 90)) == "您已超速，限速60公里")
    }

    @Test("F-17 nearest limited camera wins, facility limit is the fallback")
    func limitMerge() {
        var monitor = OverspeedMonitor(clock: clock)
        monitor.observe(cameras: [
            CameraInfo(distanceMeters: 50, speedLimitKmh: 0),
            CameraInfo(distanceMeters: 300, speedLimitKmh: 80),
            CameraInfo(distanceMeters: 120, speedLimitKmh: 60),
        ])
        #expect(monitor.limitKmh == 60)
        monitor.observe(cameras: [])
        #expect(monitor.observe(info(speed: 50, facility: 40)) == "您已超速，限速40公里")
        #expect(monitor.limitKmh == 40)
    }
}
