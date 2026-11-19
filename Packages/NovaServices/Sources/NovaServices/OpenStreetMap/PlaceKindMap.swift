import NovaPorts

/// F-15b §46 item 6 (T-040r): the kind of a place from the vendor's own category. Pure.
public enum PlaceKindMap {
    /// Photon's `osm_key` and `osm_value` (for example `amenity:place_of_worship`); nil when no key is given.
    public static func osm(key: String?, value: String?) -> PlaceKind? {
        guard let key = key?.lowercased(), !key.isEmpty else { return nil }
        let value = (value ?? "").lowercased()
        switch (key, value) {
        case ("amenity", "place_of_worship"), ("building", "temple"), ("building", "shrine"), ("building", "church"),
             ("building", "cathedral"), ("historic", "temple"), ("historic", "shrine"):
            return .temple
        case ("man_made", "tower"), ("tourism", "viewpoint"), ("man_made", "observation_tower"):
            return .tower
        case ("leisure", "park"), ("leisure", "garden"), ("leisure", "nature_reserve"), ("boundary", "national_park"),
             ("natural", _):
            return .park
        case ("tourism", "museum"), ("tourism", "gallery"), ("amenity", "arts_centre"):
            return .museum
        case ("tourism", "hotel"), ("tourism", "hostel"), ("tourism", "guest_house"), ("tourism", "motel"),
             ("tourism", "apartment"):
            return .hotel
        case ("aeroway", "aerodrome"), ("aeroway", "terminal"):
            return .airport
        case ("amenity", "car_rental"):
            return .rental
        case ("shop", _), ("amenity", "marketplace"):
            return .shop
        case ("amenity", "restaurant"), ("amenity", "cafe"), ("amenity", "fast_food"), ("amenity", "food_court"),
             ("amenity", "bar"), ("amenity", "pub"):
            return .food
        default:
            return .other
        }
    }

    /// 高德's `type` (「风景名胜;寺庙道观;寺庙道观」); nil when empty.
    public static func amap(type: String?) -> PlaceKind? {
        guard let type, !type.isEmpty else { return nil }
        let rules: [([String], PlaceKind)] = [
            (["机场"], .airport),
            (["租车", "汽车租赁"], .rental),
            (["宾馆酒店", "住宿服务", "酒店", "宾馆"], .hotel),
            (["寺庙", "道观", "教堂", "清真寺", "宗教"], .temple),
            (["博物馆", "美术馆", "展览馆", "纪念馆", "科技馆"], .museum),
            (["观景", "塔"], .tower),
            (["公园", "植物园", "动物园", "风景区", "国家级景点", "省级景点", "自然"], .park),
            (["餐饮服务", "餐厅", "小吃", "咖啡"], .food),
            (["购物服务", "商场", "市场", "超市"], .shop),
        ]
        for (words, kind) in rules where words.contains(where: { type.contains($0) }) { return kind }
        return .other
    }
}
