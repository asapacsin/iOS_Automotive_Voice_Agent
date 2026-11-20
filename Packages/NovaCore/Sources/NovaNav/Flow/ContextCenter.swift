import NovaPorts

/// F-09b §14 item 1 (T-031p): where the `[系统] 现在` note says the car is. `trip` is the trip location's name
/// (the next stop, or 「模拟车」) while the trip cards are shown (F-15b §51 item 9); nil for the phone's fix.
public struct ContextCenter: Sendable, Hashable {
    public let coordinate: GeoCoordinate
    public let trip: String?

    public init(coordinate: GeoCoordinate, trip: String?) {
        self.coordinate = coordinate
        self.trip = trip
    }
}
