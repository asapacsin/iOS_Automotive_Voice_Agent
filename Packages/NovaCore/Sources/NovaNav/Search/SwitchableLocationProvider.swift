import NovaKit
import NovaPorts

/// F-16a 位置来源: the phone's own position or the demo start point, read per request from the setting so a
/// change in 设置 applies to the next question without restarting the conversation.
public struct SwitchableLocationProvider: LocationProvider, LocationUpdates {
    private let device: any LocationProvider
    private let demo: any LocationProvider
    private let useDevice: @Sendable () -> Bool

    public init(device: any LocationProvider, demo: any LocationProvider, useDevice: @escaping @Sendable () -> Bool) {
        self.device = device
        self.demo = demo
        self.useDevice = useDevice
    }

    private var active: any LocationProvider { useDevice() ? device : demo }

    public func latestFix() async -> LocationFix? { await active.latestFix() }
    public func authorization() async -> LocationAuthorization { await active.authorization() }
    public var source: LocationSource { useDevice() ? .device : .demo }

    /// F-16b: the current source's fixes. The source is read once per call: the screen subscribes again on a
    /// 位置来源 switch (MapCameraPolicy `.sourceChanged`). A source without a stream yields its latest fix once.
    public func updates() -> AsyncStream<LocationFix> {
        let active = self.active
        if let live = active as? any LocationUpdates { return live.updates() }
        return AsyncStream { continuation in
            let task = Task {
                if let fix = await active.latestFix() { continuation.yield(fix) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
