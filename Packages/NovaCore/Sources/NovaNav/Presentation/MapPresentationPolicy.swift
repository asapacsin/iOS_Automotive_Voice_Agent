import NovaKit
import NovaPorts

/// F-25 / contracts/navigation.md (P59): what the map may draw for a flow snapshot. A route line only
/// for routes on offer or the chosen one while navigating; nothing after cancel or arrival-reset.
/// Pure, so the rule holds whichever map view draws it (MapKit now, `AmapMapView` later, T-044).
public struct MapPresentation: Sendable, Hashable {
    public enum ListKind: Sendable, Hashable { case places, routes }

    /// Route ids to draw, and the highlighted one.
    public let routes: Set<RouteID>
    public let highlighted: RouteID?
    /// Numbered markers for the listed places (destination list or along-route list).
    public let markers: [Place]
    public let destination: Place?
    public let list: ListKind?
    /// Follow the car (navigating) instead of fitting the routes.
    public let followCar: Bool

    public init(_ flow: NavigationFlowState) {
        switch flow.phase {
        case .awaitingRouteSelection:
            routes = Set(flow.routes.map(\.id))
            highlighted = flow.selectedRoute
        case .navigating, .arrived:
            let chosen = flow.selectedRoute ?? flow.routes.first?.id
            routes = chosen.map { [$0] } ?? []
            highlighted = chosen
        default:
            routes = []
            highlighted = nil
        }
        let listing = flow.phase == .awaitingDestinationSelection || flow.alongRouteList
        markers = listing ? flow.places : []
        destination = flow.phase == .idle || flow.phase == .error ? nil : flow.destination
        list = listing ? .places : flow.phase == .awaitingRouteSelection ? .routes : nil
        followCar = flow.phase == .navigating
    }
}

/// F-25 §10 row 2 (I-6): a tap on a list row is the same `choose_navigation_option` call the voice
/// path makes, run by the same executor, so it gets the same codes (`OPTIONS_STALE`, ...).
public enum ChoiceTap {
    public static func call(row index: Int, id: CallID) -> ToolCall {
        ToolCall(id: id, name: "choose_navigation_option", arguments: ["index": .int(Int64(index + 1))])
    }
}
