import Foundation
import Network
import NovaKit

/// F-24 §14 item 1: `NWPathMonitor` behind `NetworkPathEvaluator`. `onChange(false)` when the path stays
/// unavailable for 500 ms, `onChange(true)` as soon as it is available again. Runs between `start` and `stop`
/// (only while a voice session exists).
/// F-24 §16 item 1 (T-016k): available means satisfied and using Wi-Fi, cellular or wired Ethernet; a VPN tunnel
/// that stays satisfied with nothing under it is unavailable. `log` gets each `networkPath` change.
public final class NetworkPathWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "novadrive.network-path")
    private var monitor: NWPathMonitor?
    private let requirePhysicalInterface: Bool
    private var evaluator: NetworkPathEvaluator
    private let clock = SystemClock()
    private let onChange: @Sendable (Bool) -> Void
    private let log: @Sendable (DiagnosticEvent) -> Void

    public init(tuning: RealtimeTuning = RealtimeTuning(), log: @escaping @Sendable (DiagnosticEvent) -> Void = { _ in },
                onChange: @escaping @Sendable (Bool) -> Void) {
        requirePhysicalInterface = tuning.requirePhysicalInterface
        evaluator = NetworkPathEvaluator(requirePhysicalInterface: tuning.requirePhysicalInterface)
        self.log = log
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard monitor == nil else { return }
            evaluator = NetworkPathEvaluator(requirePhysicalInterface: requirePhysicalInterface)
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in self?.update(Self.snapshot(path)) }
            self.monitor = monitor
            monitor.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            monitor?.cancel()
            monitor = nil
        }
    }

    /// `usesInterfaceType` sees through a VPN path to the real interface under it (`utun5 … uses wifi`).
    private static func snapshot(_ path: NWPath) -> NetworkPathSnapshot {
        NetworkPathSnapshot(satisfied: path.status == .satisfied,
                            wifi: path.usesInterfaceType(.wifi),
                            cellular: path.usesInterfaceType(.cellular),
                            wired: path.usesInterfaceType(.wiredEthernet),
                            other: path.usesInterfaceType(.other))
    }

    /// On `queue`.
    private func update(_ snapshot: NetworkPathSnapshot) {
        guard monitor != nil else { return }
        let (line, report, tickAt) = evaluator.path(snapshot, at: clock.now)
        if let line { log(line) }
        if let report { onChange(report) }
        if let tickAt {
            let ms = max(0, (tickAt - clock.now).milliseconds)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(ms))) { [weak self] in
                guard let self, monitor != nil, let report = evaluator.tick(at: clock.now) else { return }
                onChange(report)
            }
        }
    }
}
