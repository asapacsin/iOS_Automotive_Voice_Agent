import Combine
import CoreLocation
import Foundation

/// F-16a: the When In Use state for 设置 → 位置来源; asks once when 手机定位 is chosen.
@MainActor
public final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published private var status: CLAuthorizationStatus

    override public init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    public var denied: Bool { status == .denied || status == .restricted }

    public var label: String {
        switch status {
        case .notDetermined: "未询问"
        case .denied, .restricted: "未允许"
        default: "已允许"
        }
    }

    public func request() {
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}
