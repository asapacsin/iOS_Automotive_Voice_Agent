import Foundation
import NovaPorts

/// WGS-84 (CoreLocation) → GCJ-02 (Amap), the published offset formula. Outside mainland China the
/// datums coincide and the coordinate is returned unchanged.
public enum CoordinateConverter {
    private static let a = 6_378_245.0
    private static let ee = 0.006_693_421_622_965_943

    public static func gcj02(_ c: GeoCoordinate) -> GeoCoordinate {
        guard c.datum == .wgs84 else { return c }
        guard !outOfChina(c.latitude, c.longitude) else {
            return GeoCoordinate(latitude: c.latitude, longitude: c.longitude, datum: .gcj02)
        }
        var dLat = latitudeOffset(c.longitude - 105, c.latitude - 35)
        var dLng = longitudeOffset(c.longitude - 105, c.latitude - 35)
        let radLat = c.latitude / 180 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = magic.squareRoot()
        dLat = (dLat * 180) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLng = (dLng * 180) / (a / sqrtMagic * cos(radLat) * .pi)
        return GeoCoordinate(latitude: c.latitude + dLat, longitude: c.longitude + dLng, datum: .gcj02)
    }

    static func outOfChina(_ lat: Double, _ lng: Double) -> Bool {
        lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271
    }

    private static func latitudeOffset(_ x: Double, _ y: Double) -> Double {
        var r = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * abs(x).squareRoot()
        r += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        r += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        r += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return r
    }

    private static func longitudeOffset(_ x: Double, _ y: Double) -> Double {
        var r = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * abs(x).squareRoot()
        r += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        r += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        r += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return r
    }
}
