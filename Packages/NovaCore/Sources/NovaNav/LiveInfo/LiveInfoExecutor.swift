import NovaKit
import NovaPorts
import NovaTools

/// `query_live_info` (F-18): route_traffic from the running guidance, weather from Amap Web. Answers
/// only from returned data; anything without a data source is an honest `LIVE_INFO_UNAVAILABLE` (I-1).
public struct LiveInfoExecutor: ToolExecutor {
    private let navigation: NavigationController
    private let weather: (any WeatherService)?
    private let geocoder: (any ReverseGeocoder)?
    private let location: any LocationProvider

    public init(navigation: NavigationController, weather: (any WeatherService)?, geocoder: (any ReverseGeocoder)?,
                location: any LocationProvider) {
        self.navigation = navigation
        self.weather = weather
        self.geocoder = geocoder
        self.location = location
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        switch call.arguments["kind"]?.stringValue {
        case "route_traffic":
            return await navigation.routeStatus()
        case "weather":
            return await weatherReport(call.arguments)
        case "current_location":
            return await currentLocation()
        case "along_route":
            return await navigation.alongRoute(category: call.arguments["category"]?.stringValue)
        case "place_details":
            return await navigation.placeDetails(target: call.arguments["target"])
        default:
            return .failure(.liveInfoUnavailable, advice: "这项信息在 iOS 上还没有数据源。请如实说暂时查不到，不要编造。")
        }
    }

    private func weatherReport(_ args: JSONValue) async -> ToolResult {
        guard let weather else {
            return .failure(.amapWebKeyMissing, advice: "天气查询还没有配置。请如实说明，不要编造。")
        }
        let target = args["where"]?.stringValue ?? "here"
        let forecast = args["day"]?.stringValue == "tomorrow"
        do {
            let place: String
            switch target {
            case "here", "":
                if await location.authorization() == .denied { return Self.permissionDenied }
                guard let here = await navigation.currentPosition(), let geocoder,
                      let adcode = try await geocoder.adcode(at: here) else {
                    return .failure(.noLocation, advice: "现在拿不到位置。请如实说明，可以请用户说城市名。")
                }
                place = adcode
            case "destination":
                guard let destination = await navigation.current.destination else {
                    return .failure(.noDestination, advice: "现在没有导航目的地。请如实说明。")
                }
                guard let geocoder, let adcode = try await geocoder.adcode(at: destination.coordinate) else {
                    return .failure(.noLocation, advice: "目的地的位置没有查到。请如实说明。")
                }
                place = adcode
            default:
                place = target
            }
            let report = try await weather.weather(adcode: place, forecast: forecast)
            return .success(["weather": report.summary,
                             "next": "只按 weather 里的数据用一两句话回答，不要编造。"])
        } catch {
            return Self.failure(error)
        }
    }

    static func failure(_ error: any Error) -> ToolResult { LiveInfoFailure.result(error, what: "天气") }

    // MARK: current_location

    /// F-16a 「我现在在哪？」: the regeo address of the same position search, weather and routing use.
    private func currentLocation() async -> ToolResult {
        if await location.authorization() == .denied { return Self.permissionDenied }
        guard let geocoder else {
            return .failure(.amapWebKeyMissing, advice: "高德的查询服务还没有配置，所以查不到地址。请如实说明，不要猜位置。")
        }
        guard let here = await navigation.currentPosition() else {
            return .failure(.noLocation, advice: "现在还没定位到。请如实说还没定位到，稍后再问；不要猜位置。")
        }
        do {
            guard let address = try await geocoder.address(at: here), !address.formatted.isEmpty else {
                return .failure(.noLocation, advice: "地址没有查到。请如实说明，不要猜位置。")
            }
            let demo = location.source == .demo
            var data: [String: JSONValue] = [
                "address": .string(Self.trimProvince(address.formatted)),
                "source": .string(location.source.rawValue),
                "next": .string(demo
                    ? "只按 address 用一句话回答，并说明这是演示起点，不是真实位置。不要编造。"
                    : "只按 address 用一句话回答（例如：你现在在……附近）。不要编造。"),
            ]
            if let district = address.district { data["district"] = .string(district) }
            if let road = address.road, !road.isEmpty { data["road"] = .string(road) }
            return .success(data)
        } catch let error as AmapWebError where error != .timeout && error != .failed {
            return LiveInfoFailure.result(error, what: "地址")
        } catch {
            // F-18 §8: a failed regeo is "no location", not a generic outage.
            return .failure(.noLocation, advice: "地址没有查到。请如实说明，不要猜位置。")
        }
    }

    static let permissionDenied = ToolResult.failure(
        .locationPermissionDenied, advice: "定位权限没有打开。请用一句话如实说定位权限没有打开，可以在设置里允许；不要猜位置。")

    /// 「广东省珠海市香洲区…」 → 「珠海市香洲区…」: the province adds nothing when a city follows it.
    static func trimProvince(_ address: String) -> String {
        for marker in ["省", "自治区"] {
            if let range = address.range(of: marker) {
                let rest = address[range.upperBound...]
                return rest.contains("市") ? String(rest) : address
            }
        }
        return address
    }
}

/// F-18 §8: the cause she names must be the real one (key, quota, or network/timeout).
enum LiveInfoFailure {
    static func result(_ error: any Error, what: String) -> ToolResult {
        switch error as? AmapWebError {
        case .keyMissing, .keyRejected:
            .failure(.amapWebKeyMissing, advice: "高德的查询服务没有配置好或密钥无效，所以没有查到。请如实说明，不要编造。")
        case .quota:
            .failure(.liveInfoQuota, advice: "今天的查询次数用完了，没有查到。请如实说明，不要编造。")
        default:
            .failure(.liveInfoUnavailable, advice: "\(what)没有查到。请如实说明，不要编造。")
        }
    }
}
