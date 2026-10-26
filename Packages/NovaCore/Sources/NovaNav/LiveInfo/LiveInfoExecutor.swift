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
                guard let fix = await location.latestFix(), let geocoder,
                      let adcode = try await geocoder.adcode(at: fix.coordinate) else {
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

    /// F-18 §8: the cause she names must be the real one (key, quota, or network/timeout).
    static func failure(_ error: any Error) -> ToolResult {
        switch error as? AmapWebError {
        case .keyMissing, .keyRejected:
            .failure(.amapWebKeyMissing, advice: "高德的查询服务没有配置好或密钥无效，所以没有查到。请如实说明，不要编造。")
        case .quota:
            .failure(.liveInfoQuota, advice: "今天的查询次数用完了，没有查到。请如实说明，不要编造。")
        default:
            .failure(.liveInfoUnavailable, advice: "天气没有查到。请如实说明，不要编造。")
        }
    }
}
