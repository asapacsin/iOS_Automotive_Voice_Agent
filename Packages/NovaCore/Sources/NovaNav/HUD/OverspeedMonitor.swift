import NovaKit
import NovaPorts

/// F-17 overspeed alert (contracts/navigation.md Overspeed). Feed it `cameraInfo` and `naviInfo` events
/// in arrival order; `observe(_:)` returns the text to speak, or nil.
public struct OverspeedMonitor: Sendable {
    /// Minimum gap between two alerts (navigation.md: 10 000 ms).
    public static let minimumGap = NovaDuration.milliseconds(10_000)

    private let clock: any NovaClock
    private var cameraLimitKmh = 0
    private var facilityLimitKmh = 0
    /// True until an alert fires for the current exceedance; dropping back to or under the limit re-arms.
    private var armed = true
    private var lastAlertLimitKmh: Int?
    private var lastAlertAt: NovaInstant?

    public init(clock: any NovaClock) {
        self.clock = clock
    }

    /// Effective limit: nearest camera with limit > 0, else the facility limit; 0 = no data.
    /// Camera-over-facility precedence is PROPOSED pending `OverspeedAlert.kt` via EVIDENCE_REQUEST.
    public var limitKmh: Int { cameraLimitKmh > 0 ? cameraLimitKmh : facilityLimitKmh }

    public static func alertText(limitKmh: Int) -> String { "您已超速，限速\(limitKmh)公里" }

    /// Keeps the nearest camera that carries a limit; cameras with limit 0 carry no data.
    public mutating func observe(cameras: [CameraInfo]) {
        let limited = cameras.filter { $0.speedLimitKmh > 0 }
        cameraLimitKmh = limited.min { $0.distanceMeters < $1.distanceMeters }?.speedLimitKmh ?? 0
    }

    /// Evaluates the current speed against the effective limit.
    public mutating func observe(_ info: NaviInfo) -> String? {
        facilityLimitKmh = max(info.facilityLimitKmh, 0)
        let limit = limitKmh
        // Limit 0 = no data: never alerts and leaves the arming state unchanged.
        guard limit > 0, let speed = info.currentSpeedKmh else { return nil }
        guard speed > limit else {
            armed = true
            return nil
        }
        let limitChanged = lastAlertLimitKmh.map { $0 != limit } ?? false
        guard armed || limitChanged else { return nil }
        let now = clock.now
        if let last = lastAlertAt, now - last < Self.minimumGap { return nil }
        armed = false
        lastAlertLimitKmh = limit
        lastAlertAt = now
        return Self.alertText(limitKmh: limit)
    }
}
