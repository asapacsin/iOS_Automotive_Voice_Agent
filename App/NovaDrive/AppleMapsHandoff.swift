import MapKit
import NovaPorts

/// F-15b §38 item 2 (T-040o): opens Apple Maps with driving directions to a trip stop when 高德's route fails abroad.
@MainActor
enum AppleMapsHandoff {
    static func open(_ place: Place) -> Bool {
        let c = CLLocationCoordinate2D(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
        item.name = place.name
        return item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}
