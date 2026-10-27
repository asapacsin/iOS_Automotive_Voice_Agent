import NovaKit
import NovaPorts

/// F-16a 位置来源: the phone's own position or the demo start point, read per request from the setting so a
/// change in 设置 applies to the next question without restarting the conversation.
public struct SwitchableLocationProvider: LocationProvider {
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
}
