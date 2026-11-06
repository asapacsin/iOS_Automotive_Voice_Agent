/// F-24 §16 item 1 (T-016k): what one network path reports, without Network framework types. `other`: the path
/// also uses some other interface (a VPN tunnel such as `utun5`, loopback).
public struct NetworkPathSnapshot: Sendable, Hashable {
    public var satisfied: Bool
    public var wifi: Bool
    public var cellular: Bool
    public var wired: Bool
    public var other: Bool

    public init(satisfied: Bool, wifi: Bool, cellular: Bool, wired: Bool, other: Bool) {
        self.satisfied = satisfied
        self.wifi = wifi
        self.cellular = cellular
        self.wired = wired
        self.other = other
    }

    /// Network means a real interface: satisfied and using Wi-Fi, cellular or wired Ethernet. A satisfied path with
    /// only a tunnel or other interface is unavailable, unless `requirePhysicalInterface` is off.
    public func available(requirePhysicalInterface: Bool = true) -> Bool {
        guard satisfied else { return false }
        return !requirePhysicalInterface || wifi || cellular || wired
    }

    /// The `networkPath` line: the first real interface used, or none.
    public var via: NetworkPathVia { wifi ? .wifi : cellular ? .cell : wired ? .wired : .none }

    public var diagnostic: DiagnosticEvent { .networkPath(satisfied: satisfied, via: via, tunnel: other) }
}

/// F-24 §16 item 1: `via=` of the `networkPath` line.
public enum NetworkPathVia: String, Sendable, Hashable, CaseIterable {
    case wifi, cell, wired, none
}

/// F-24 §16 item 1: the watcher's logic over snapshots, pure so it is testable without `NWPathMonitor`: each change
/// is logged once, and availability goes through the unchanged §14 500 ms debounce.
public struct NetworkPathEvaluator: Sendable {
    private var debouncer: NetworkPathDebouncer
    private var last: NetworkPathSnapshot?
    private let requirePhysicalInterface: Bool

    public init(requirePhysicalInterface: Bool = RealtimeTuning().requirePhysicalInterface,
                debounce: NovaDuration = .milliseconds(500)) {
        self.requirePhysicalInterface = requirePhysicalInterface
        debouncer = NetworkPathDebouncer(delay: debounce)
    }

    public var available: Bool { debouncer.available }

    /// The path changed. `log`: the `networkPath` line when the snapshot differs from the last one; `report` and
    /// `tickAt` as `NetworkPathDebouncer.path`.
    public mutating func path(_ snapshot: NetworkPathSnapshot, at now: NovaInstant)
        -> (log: DiagnosticEvent?, report: Bool?, tickAt: NovaInstant?) {
        let log = snapshot == last ? nil : snapshot.diagnostic
        last = snapshot
        let (report, tickAt) = debouncer.path(satisfied: snapshot.available(requirePhysicalInterface: requirePhysicalInterface),
                                              at: now)
        return (log, report, tickAt)
    }

    public mutating func tick(at now: NovaInstant) -> Bool? { debouncer.tick(at: now) }
}
