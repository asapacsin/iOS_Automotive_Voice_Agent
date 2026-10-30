import Foundation
import Network
import NovaKit

/// F-24 §14 item 1: `NWPathMonitor` behind `NetworkPathDebouncer`. `onChange(false)` when the path stays
/// unsatisfied for 500 ms, `onChange(true)` as soon as it is satisfied again. Runs between `start` and `stop`
/// (only while a voice session exists).
public final class NetworkPathWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "novadrive.network-path")
    private var monitor: NWPathMonitor?
    private var debouncer = NetworkPathDebouncer()
    private let clock = SystemClock()
    private let onChange: @Sendable (Bool) -> Void

    public init(onChange: @escaping @Sendable (Bool) -> Void) { self.onChange = onChange }

    public func start() {
        queue.async { [self] in
            guard monitor == nil else { return }
            debouncer = NetworkPathDebouncer()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in self?.update(satisfied: path.status == .satisfied) }
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

    /// On `queue`.
    private func update(satisfied: Bool) {
        guard monitor != nil else { return }
        let (report, tickAt) = debouncer.path(satisfied: satisfied, at: clock.now)
        if let report { onChange(report) }
        if let tickAt {
            let ms = max(0, (tickAt - clock.now).milliseconds)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(ms))) { [weak self] in
                guard let self, monitor != nil, let report = debouncer.tick(at: clock.now) else { return }
                onChange(report)
            }
        }
    }
}
