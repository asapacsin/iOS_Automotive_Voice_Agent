import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-16 saved places (`A/nav/SavedPlaces.kt`, `SavedPlaceStore.kt`): one `Place` per slot, kept in
/// local settings. The coordinate is stored as Amap returned it (GCJ-02) and never converted again
/// (F-16 §10 row 4).
public struct SavedPlaces: Sendable {
    private let settings: any SettingsStore

    public init(settings: any SettingsStore) { self.settings = settings }

    static func key(_ slot: PlaceSlot) -> String { "saved_place_\(slot.rawValue)" }

    private struct Stored: Codable {
        var name: String
        var address: String?
        var latitude: Double
        var longitude: Double
        var datum: String
    }

    public func place(_ slot: PlaceSlot) -> Place? {
        guard let text = settings.string(Self.key(slot)),
              let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8)),
              let datum = CoordinateDatum(rawValue: stored.datum) else { return nil }
        return Place(id: "saved_\(slot.rawValue)", name: stored.name, address: stored.address,
                     coordinate: GeoCoordinate(latitude: stored.latitude, longitude: stored.longitude, datum: datum),
                     distanceMeters: nil)
    }

    public func save(_ place: Place, in slot: PlaceSlot) {
        let stored = Stored(name: place.name, address: place.address, latitude: place.coordinate.latitude,
                            longitude: place.coordinate.longitude, datum: place.coordinate.datum.rawValue)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        settings.set(String(decoding: data, as: UTF8.self), for: Self.key(slot))
    }

    /// Slots that hold a place.
    public var setSlots: Set<PlaceSlot> { Set(PlaceSlot.allCases.filter { place($0) != nil }) }
}

/// `save_place`: finds the spoken address with an Amap text search (first result) and saves it.
/// Says nothing is saved unless it was (I-1).
public struct SavePlaceExecutor: ToolExecutor {
    public static let tool = "save_place"

    private let places: SavedPlaces
    private let search: any PlaceSearch

    public init(places: SavedPlaces, search: any PlaceSearch) {
        self.places = places
        self.search = search
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        guard let raw = call.arguments["slot"]?.stringValue, let slot = PlaceSlot(rawValue: raw) else {
            return .failure(.invalidFieldValue, advice: "没有说清是家还是公司。请如实说没有保存，问用户是家还是公司。")
        }
        let address = (call.arguments["address"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            return .failure(.invalidFieldValue, advice: "没有听到地址。请如实说没有保存，请用户再说一遍地址。")
        }
        let found: [Place]
        do {
            found = try await search.text(address, city: nil)
        } catch let error as AmapWebError {
            if error == .keyMissing || error == .keyRejected {
                return .failure(.amapWebKeyMissing, advice: "高德的查询服务还没有配置好，地址没有保存。请如实说明。")
            }
            return .failure(.liveInfoUnavailable, advice: "地址查询失败了，没有保存。请如实说明，可以请用户稍后再说一遍。")
        } catch {
            return .failure(.liveInfoUnavailable, advice: "地址查询失败了，没有保存。请如实说明。")
        }
        guard let first = found.first else {
            return .failure(.noCandidates, advice: "没有找到这个地址，没有保存。请如实说明，请用户换个说法。")
        }
        let saved = Place(id: "saved_\(slot.rawValue)", name: first.name, address: first.address ?? address,
                          coordinate: first.coordinate, distanceMeters: nil)
        places.save(saved, in: slot)
        // Claim only what the store holds now (I-1): read the slot back.
        guard let stored = places.place(slot), stored.name == saved.name,
              stored.coordinate == saved.coordinate else {
            return .failure(.placeNotSaved, advice: "地址没有保存成功。请如实说没有保存，可以请用户稍后再试。")
        }
        let label = slot == .home ? "家" : "公司"
        let ask = slot == .home ? "回家" : "去公司"
        return .success([
            "slot": .string(slot.rawValue),
            "name": .string(saved.name),
            "next": .string("只说一句：已把\(saved.name)记为\(label)，以后说「\(ask)」就能直接导航。"),
        ])
    }
}
