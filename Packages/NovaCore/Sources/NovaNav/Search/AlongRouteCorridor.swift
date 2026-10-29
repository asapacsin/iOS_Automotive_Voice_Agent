import Foundation
import NovaKit
import NovaPorts

/// F-16 along-route corridor (`A/nav/AlongRouteCorridor.kt:89-96`): the route simplified to 50 m, then
/// widened 500 m to each side, as a closed polygon of at most 64 vertices for `/v3/place/polygon`.
/// GCJ-02 in, GCJ-02 out. Pure.
///
/// PROPOSED: the widening (per-vertex mitred normals) and growing the simplification tolerance by 1.5×
/// until the vertex limit holds; the Android corridor tests are an EVIDENCE_REQUEST.
public enum AlongRouteCorridor {
    public static func polygon(_ route: [GeoCoordinate], tuning: AmapWebTuning = AmapWebTuning()) -> [GeoCoordinate] {
        guard route.count >= 2, let origin = route.first else { return [] }
        let projection = Projection(origin: origin)
        let points = route.map(projection.forward)
        // Two sides plus the closing vertex.
        let maxCenter = max((tuning.corridorMaxVertices - 1) / 2, 2)
        var tolerance = Double(tuning.corridorSimplifyMeters)
        var line = simplify(points, tolerance: tolerance)
        while line.count > maxCenter {
            tolerance *= 1.5
            line = simplify(points, tolerance: tolerance)
        }
        guard line.count >= 2 else { return [] }
        let half = Double(tuning.corridorHalfWidthMeters)
        var left: [Point] = []
        var right: [Point] = []
        for i in line.indices {
            let normal = vertexNormal(line, i)
            left.append(Point(x: line[i].x + normal.x * half, y: line[i].y + normal.y * half))
            right.append(Point(x: line[i].x - normal.x * half, y: line[i].y - normal.y * half))
        }
        let ring = left + right.reversed()
        return (ring + [ring[0]]).map(projection.inverse)
    }

    struct Point: Hashable {
        var x: Double
        var y: Double
    }

    /// Equirectangular metres around the first point: exact enough over a city-scale route.
    struct Projection {
        let origin: GeoCoordinate
        let metersPerDegree = 111_320.0

        func forward(_ c: GeoCoordinate) -> Point {
            Point(x: (c.longitude - origin.longitude) * metersPerDegree * cos(origin.latitude * .pi / 180),
                  y: (c.latitude - origin.latitude) * metersPerDegree)
        }

        func inverse(_ p: Point) -> GeoCoordinate {
            GeoCoordinate(latitude: origin.latitude + p.y / metersPerDegree,
                          longitude: origin.longitude + p.x / (metersPerDegree * cos(origin.latitude * .pi / 180)),
                          datum: origin.datum)
        }
    }

    /// Douglas–Peucker.
    static func simplify(_ points: [Point], tolerance: Double) -> [Point] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var worst = 0.0
            var index = start
            for i in (start + 1)..<end {
                let d = distance(points[i], from: points[start], to: points[end])
                if d > worst {
                    worst = d
                    index = i
                }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((start, index))
                stack.append((index, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    static func distance(_ p: Point, from a: Point, to b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Unit left normal at vertex `i`: the mean of its segments' normals (a mitre limited to 2× width).
    static func vertexNormal(_ line: [Point], _ i: Int) -> Point {
        func segmentNormal(_ a: Point, _ b: Point) -> Point {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(hypot(dx, dy), 1e-9)
            return Point(x: -dy / length, y: dx / length)
        }
        let before = i > 0 ? segmentNormal(line[i - 1], line[i]) : nil
        let after = i + 1 < line.count ? segmentNormal(line[i], line[i + 1]) : nil
        guard let n1 = before ?? after, let n2 = after ?? before else { return Point(x: 0, y: 0) }
        let sum = Point(x: n1.x + n2.x, y: n1.y + n2.y)
        let length = hypot(sum.x, sum.y)
        guard length > 1e-9 else { return n1 }
        // Scale so the offset edge stays `half` away from both segments, capped at 2×.
        let cosHalf = (sum.x * n1.x + sum.y * n1.y) / length
        let scale = min(1 / max(cosHalf, 0.5), 2)
        return Point(x: sum.x / length * scale, y: sum.y / length * scale)
    }
}
