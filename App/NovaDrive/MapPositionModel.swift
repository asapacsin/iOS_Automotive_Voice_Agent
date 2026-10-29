import Combine
import Foundation
import NovaKit
import NovaNav
import NovaPlatform
import NovaPorts
import UIKit

/// A camera move the view must apply. `id` changes with every command, so the same command twice moves twice.
struct CameraCommand: Equatable {
    let id: Int
    let command: MapCameraPolicy.Command
}

/// T-044c (F-16b): the drive screen's 我的位置. It consumes the current source's fixes (no polling of
/// `latestFix()`), turns them into `SelfPosition` and runs `MapCameraPolicy`; the view only draws what it
/// publishes and reports gestures. Lives as long as the app; streams run only while the screen is visible.
@MainActor
final class MapPositionModel: ObservableObject {
    @Published private(set) var position: SelfPosition
    @Published private(set) var locate: LocateButton
    @Published private(set) var command: CameraCommand?

    private var policy = MapCameraPolicy()
    private let clock: SystemClock
    private let device: CoreLocationProvider
    private let location: SwitchableLocationProvider
    private let permissionAsker = LocationPermission()
    private var fix: LocationFix?
    private var permission = LocationAuthorization.notDetermined
    private var source: LocationSource
    private var phase = NavigationPhase.idle
    private var car: GeoCoordinate?
    private var carHeading: Double?
    private var streaming: Task<Void, Never>?
    private var ticking: Task<Void, Never>?
    private var commands = 0
    private var lastEvaluation = NovaInstant.zero

    init(device: CoreLocationProvider, demo: any LocationProvider, clock: SystemClock) {
        self.device = device
        self.clock = clock
        location = SwitchableLocationProvider(device: device, demo: demo,
                                              useDevice: { DriveSettings.usesDeviceLocation() })
        source = location.source
        let hidden = SelfPosition.make(SelfPosition.Input(fix: nil, source: location.source,
                                                          permission: .notDetermined, now: clock.now))
        position = hidden
        locate = LocateButton(hidden, mode: .awaitingFirstFix)
    }

    // MARK: Lifecycle (F-16b §9: only while the drive screen is visible)

    func appear() {
        guard streaming == nil else { return }
        subscribe()
        ticking = Task { [weak self] in
            // 1 s: drives the 15 s auto-recenter on time; the 5 s re-evaluation is counted inside.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
    }

    func disappear() {
        streaming?.cancel()
        ticking?.cancel()
        streaming = nil
        ticking = nil
    }

    /// 位置来源 changed in 设置 (C11): a new stream, and the first fix recenters again.
    func sourceChanged() {
        guard location.source != source else { return }
        source = location.source
        fix = nil
        apply(policy.handle(.sourceChanged))
        streaming?.cancel()
        streaming = nil
        if ticking != nil { subscribe() }
        evaluate()
    }

    private func subscribe() {
        let stream = location.updates()
        let device = device
        let useDevice = source == .device
        streaming = Task { [weak self] in
            // The phone's provider yields only once started; it was asked for permission at first need.
            if useDevice, await device.authorization() == .authorized { await device.start() }
            for await fix in stream {
                guard !Task.isCancelled else { return }
                self?.received(fix)
            }
        }
        Task { await refreshPermission() }
    }

    // MARK: Inputs

    private func received(_ fix: LocationFix) {
        self.fix = fix
        evaluate()
    }

    /// The flow and the simulated car (OQ-MAP-2: while navigating it is 我的位置).
    func navigation(_ flow: NavigationFlowState, geometry: RouteGeometry) {
        if let next = geometry.car, let previous = car, let bearing = SelfPosition.bearing(from: previous, to: next) {
            carHeading = bearing
        }
        car = flow.navigating ? geometry.car : nil
        if car == nil { carHeading = nil }
        phase = flow.phase
        apply(policy.handle(.framing(MapCameraPolicy.framing(MapPresentation(flow)), at: clock.now)))
        evaluate()
    }

    /// A pan or zoom the driver made (never a move this model commanded).
    func userGesture() {
        apply(policy.handle(.userGesture(at: clock.now)))
        locate = LocateButton(position, mode: policy.mode)
    }

    /// 回到我的位置 (F-16b §2).
    func locateMe() {
        switch locate.action {
        case .recenter, .none:
            apply(policy.handle(.locateMe(at: clock.now)))
        case .askPermission:
            permissionAsker.request()
        case .openSettings:
            openSettings()
        }
        locate = LocateButton(position, mode: policy.mode)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func tick() async {
        await refreshPermission()
        let now = clock.now
        apply(policy.handle(.tick(at: now)))
        // §5: fresh → provisional → none by age, re-evaluated every 5 s even without a new fix.
        if now - lastEvaluation >= MapPositionTuning().reevaluateEvery { evaluate() }
        locate = LocateButton(position, mode: policy.mode)
    }

    private func refreshPermission() async {
        let current = await location.authorization()
        guard current != permission else { return }
        let granted = current == .authorized && permission != .authorized
        permission = current
        // Permission just given (locate-me asked, or 设置): start the phone's updates now.
        if granted, source == .device { await device.start() }
        evaluate()
    }

    private func evaluate() {
        let now = clock.now
        lastEvaluation = now
        position = SelfPosition.make(SelfPosition.Input(fix: fix, source: source, permission: permission, now: now,
                                                        phase: phase, simulatedCar: car,
                                                        simulatedHeadingDegrees: carHeading))
        apply(policy.handle(.position(position, at: now)))
        locate = LocateButton(position, mode: policy.mode)
        // I-8: only the style reaches diagnostics, never a coordinate.
        let style = position.marker.map { String(describing: $0.style) } ?? "none"
        RuntimeLog.agent.debug("self position \(style, privacy: .public)")
    }

    private func apply(_ next: MapCameraPolicy.Command?) {
        guard let next else { return }
        commands += 1
        command = CameraCommand(id: commands, command: next)
    }
}
