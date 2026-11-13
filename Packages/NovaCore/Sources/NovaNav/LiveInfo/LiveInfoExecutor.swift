import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// `query_live_info` (F-18): route_traffic from the running guidance, weather from 和风天气 (§31, Open-Meteo fallback). Answers
/// only from returned data; anything without a data source is an honest `LIVE_INFO_UNAVAILABLE` (I-1).
public struct LiveInfoExecutor: ToolExecutor {
    private let navigation: NavigationController
    private let geocoder: (any ReverseGeocoder)?
    private let location: any LocationProvider
    /// F-18 §14: the phone clock and time zone, read at each call.
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    /// F-18 §23 item 3: with 「联网搜索（实验）」 on, place details without hours point her to `web_search`.
    /// (§23 item 1: weather and place details stay here with search on.)
    private let webSearch: Bool
    /// F-18 §26 items 2, 4: 高德 geocoding (nil: the name goes to `weather` as before), Open-Meteo geocoding and
    /// forecast, and the `RuntimeLog` line (item 11).
    private let amapLookup: (any PlaceLookup)?
    private let forecastLookup: (any PlaceLookup)?
    private let forecast: (any DailyForecastService)?
    /// F-18 §31 (T-046t): 和风天气, the first source for every weather answer.
    private let qweather: (any ViewForecastService)?
    private let onWeather: @Sendable (WeatherSourceLog) -> Void

    public init(webSearch: Bool = false, navigation: NavigationController, geocoder: (any ReverseGeocoder)?,
                location: any LocationProvider, now: @escaping @Sendable () -> Date = { Date() },
                zone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
                amapLookup: (any PlaceLookup)? = nil, forecastLookup: (any PlaceLookup)? = nil,
                forecast: (any DailyForecastService)? = nil, qweather: (any ViewForecastService)? = nil,
                onWeather: @escaping @Sendable (WeatherSourceLog) -> Void = { _ in }) {
        self.amapLookup = amapLookup
        self.forecastLookup = forecastLookup
        self.forecast = forecast
        self.qweather = qweather
        self.onWeather = onWeather
        self.webSearch = webSearch
        self.now = now
        self.zone = zone
        self.navigation = navigation
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
        case "current_time":
            return CurrentTime.result(now: now(), zone: zone(), arguments: call.arguments)
        case "along_route":
            return await navigation.alongRoute(category: call.arguments["category"]?.stringValue)
        case "place_details":
            let result = await navigation.placeDetails(target: call.arguments["target"])
            return webSearch ? Self.searchFallback(result) : result
        default:
            return .failure(.liveInfoUnavailable, advice: "这项信息在 iOS 上还没有数据源。请如实说暂时查不到，不要编造。")
        }
    }

    /// F-18 §26 (T-046o), §28 (T-046q), §31 (T-046t): `where` (here, destination, a name), `day` (now or a whole
    /// day) or `date`, `part` and `country`. 高德 finds Chinese names; 和风 finds the rest and answers every view.
    private func weatherReport(_ args: JSONValue) async -> ToolResult {
        // §29 item 4: every weather line of this call carries how the place was found.
        // §30 item 5: the attempts of the last Open-Meteo request and the call's total time go on the line too.
        await Self.$trace.withValue(WeatherTrace()) {
            await ForecastAttempts.$current.withValue(ForecastAttempts()) { await weatherCall(args) }
        }
    }

    /// F-18 §29 item 4 (T-046r): `lookup=` for the call's log lines.
    final class WeatherTrace: @unchecked Sendable {
        var lookup = "amap"
        let started = ContinuousClock.now
    }
    @TaskLocal static var trace: WeatherTrace?

    private func weatherCall(_ args: JSONValue) async -> ToolResult {
        guard let parsed = ForecastWeather.arguments(args) else {
            return .failure(.invalidArgument, advice: ForecastWeather.argumentAdvice)
        }
        let view = parsed.view.rawValue
        // §31 item 2: find the place; every view is then answered by 和风 at its coordinates.
        let coordinate: GeoCoordinate
        let place: String
        var country: String?
        switch parsed.where {
        case "here", "":
            Self.trace?.lookup = "here"
            if await location.authorization() == .denied { return Self.permissionDenied }
            let noLocation = ToolResult.failure(.noLocation, advice: "现在拿不到位置。请如实说明，可以请用户说城市名。")
            guard let here = await navigation.currentPosition(), let geocoder else { return noLocation }
            // F-16a §8 / F-18 §8: a regeo network failure or timeout is "no location".
            let adcode: String?
            do {
                adcode = try await geocoder.adcode(at: here)
            } catch let error as AmapWebError where error == .timeout || error == .failed {
                return noLocation
            } catch {
                return Self.failure(error)
            }
            guard let adcode else { return noLocation }
            coordinate = here
            country = ForecastWeather.hongKongOrMacau(adcode: adcode)
            place = await placeName(nil, parsed, here)
        case "destination":
            guard let destination = await navigation.current.destination else {
                return .failure(.noDestination, advice: "现在没有导航目的地。请如实说明。")
            }
            let adcode = try? await geocoder?.adcode(at: destination.coordinate)
            coordinate = destination.coordinate
            country = ForecastWeather.hongKongOrMacau(adcode: adcode ?? nil)
            place = destination.name
        default:
            let abroad = parsed.country.map { $0 != "CN" } ?? !ForecastWeather.hasHan(parsed.where)
            if abroad {
                // §31 item 2: HK, MO, a foreign country, or a name with no Chinese characters: 和风's city lookup.
                Self.trace?.lookup = "qweather"
                guard let qweather else {
                    report("qweather", ok: false, reason: "nokey", view: view)
                    Self.trace?.lookup = "open-meteo"
                    return await foreignWeather(parsed)
                }
                do {
                    guard let found = try await qweather.lookUp(parsed.where, country: parsed.country).first,
                          let at = found.coordinate else { throw QWeatherError.notFound }
                    coordinate = at
                    place = found.name
                    country = ForecastWeather.hongKongOrMacau(countryCode: parsed.country)
                        ?? (found.country == "中国" ? nil : found.country ?? parsed.country)
                } catch QWeatherError.notFound {
                    report("qweather", ok: false, reason: "not_found", view: view)
                    return .failure(.liveInfoUnavailable, advice: ForecastWeather.notFoundAdvice)
                } catch {
                    // §31 item 5: a lookup failure other than "not found" uses Open-Meteo geocoding.
                    report("qweather", ok: false, reason: Self.reason(error), view: view)
                    Self.trace?.lookup = "open-meteo"
                    return await foreignWeather(parsed)
                }
            } else {
                // §26 item 2: 高德 geocoding, then the name check; a mismatch calls nothing else.
                Self.trace?.lookup = "amap"
                guard let amapLookup else { return .failure(.amapWebKeyMissing, advice: "天气查询还没有配置。请如实说明，不要编造。") }
                let found: LookedUpPlace?
                do {
                    found = try await amapLookup.lookUp(parsed.where, country: nil).first
                } catch {
                    report("amap", ok: false, reason: Self.reason(error), view: view)
                    return Self.failure(error)
                }
                guard let found, let at = found.coordinate,
                      ForecastWeather.nameMatches(parsed.where, formatted: found.formatted) else {
                    report("amap", ok: false, reason: "not_found", view: view)
                    return .failure(.liveInfoUnavailable, advice: ForecastWeather.amapNotFoundAdvice)
                }
                coordinate = at
                place = found.name
                country = ForecastWeather.hongKongOrMacau(adcode: found.adcode)
            }
        }
        return await weather(at: coordinate, place: place, country: country, parsed)
    }

    /// §31 items 3, 5: 和风 at the coordinates; no key, a timeout, a failed connection, 401/403/429/5xx or an
    /// unreadable answer falls back to Open-Meteo at the same coordinates.
    private func weather(at coordinate: GeoCoordinate, place: String, country: String?,
                         _ parsed: ForecastWeather.Arguments) async -> ToolResult {
        let okReason = ["香港", "澳门"].contains(country ?? "") ? "hkmo" : "ok"
        let view = parsed.view.rawValue
        if let qweather {
            let request: ForecastRequest = switch parsed.view { case .now: .now; case .day: .day; case .hours: .hours }
            do {
                let result = try await qweather.forecast(latitude: ForecastWeather.rounded(coordinate.latitude),
                                                         longitude: ForecastWeather.rounded(coordinate.longitude), request: request)
                return render(result, source: "qweather", place: place, country: country, parsed, okReason: okReason)
            } catch {
                report("qweather", ok: false, reason: Self.reason(error), view: view)
            }
        } else {
            report("qweather", ok: false, reason: "nokey", view: view)
        }
        return await openMeteo(at: coordinate, place: place, country: country, parsed, okReason: okReason)
    }

    /// §26 item 6, §28 item 4: `place` for an answer at `here`: the regeo district (else the address), never the
    /// word "here"; a failed regeo leaves 「当前位置」.
    private func placeName(_ name: String?, _ parsed: ForecastWeather.Arguments, _ coordinate: GeoCoordinate?) async -> String {
        if let name { return name }
        guard ["here", ""].contains(parsed.where) else { return parsed.where }
        if let coordinate, let geocoder, let address = try? await geocoder.address(at: coordinate) {
            if let district = address.district, !district.isEmpty { return district }
            if !address.formatted.isEmpty { return Self.trimProvince(address.formatted) }
        }
        return "当前位置"
    }

    /// §26 item 2, §31 item 5: Open-Meteo geocoding (largest population), then its forecast.
    private func foreignWeather(_ parsed: ForecastWeather.Arguments) async -> ToolResult {
        guard let forecastLookup else { return .failure(.liveInfoUnavailable, advice: "天气没有查到。请如实说明，不要编造。") }
        do {
            let places = try await forecastLookup.lookUp(parsed.where, country: parsed.country)
            guard let found = ForecastWeather.pick(places), let coordinate = found.coordinate else {
                report("open-meteo", ok: false, reason: "not_found", view: parsed.view.rawValue)
                return .failure(.liveInfoUnavailable, advice: ForecastWeather.notFoundAdvice)
            }
            if let hkmo = ForecastWeather.hongKongOrMacau(countryCode: parsed.country ?? found.countryCode) {
                return await openMeteo(at: coordinate, place: found.name, country: hkmo, parsed, okReason: "hkmo")
            }
            let country = found.countryCode == "CN" ? nil : found.country ?? parsed.country
            return await openMeteo(at: coordinate, place: found.name, country: country, parsed)
        } catch {
            report("open-meteo", ok: false, reason: Self.reason(error), view: parsed.view.rawValue)
            return Self.failure(error)
        }
    }

    /// §26 items 4-6, §28 items 2-4: one Open-Meteo call at coordinates rounded to 2 decimals, then the view.
    private func openMeteo(at coordinate: GeoCoordinate?, place: String, country: String?,
                           _ parsed: ForecastWeather.Arguments, okReason: String = "ok") async -> ToolResult {
        let view = parsed.view.rawValue
        guard let forecast, let coordinate else {
            report("open-meteo", ok: false, reason: "not_configured", view: view)
            return .failure(.liveInfoUnavailable, advice: Self.noForecastAdvice)
        }
        let result: DailyForecast
        do {
            result = try await forecast.dailyForecast(latitude: ForecastWeather.rounded(coordinate.latitude),
                                                    longitude: ForecastWeather.rounded(coordinate.longitude))
        } catch {
            report("open-meteo", ok: false, reason: Self.reason(error), view: view)
            return Self.failure(error)
        }
        return render(result, source: "open-meteo", place: place, country: country, parsed, okReason: okReason)
    }

    /// §26 items 5-6, §28 items 2-4, §31 item 3: one source's answer as the asked view.
    private func render(_ result: DailyForecast, source: String, place: String, country: String?,
                        _ parsed: ForecastWeather.Arguments, okReason: String) -> ToolResult {
        let view = parsed.view.rawValue
        let days = result.days
        if parsed.view == .hours, let part = parsed.part {
            return hoursResult(result, source: source, part: part, place: place, country: country, parsed, okReason: okReason)
        }
        let nowView = parsed.view == .now
        // §28 item 2: the reading now; a missing daily answer leaves `today` out.
        if nowView, let nowBlock = ForecastWeather.now(result.current) {
            let entry: DailyForecastDay? = if case .day(let e) = ForecastWeather.pick(days, day: nil, date: nil) { e } else { nil }
            let date = entry?.time ?? SearchDate.today(now(), zone: zone()).iso
            report(source, ok: true, reason: okReason, view: view)
            var w: [String: JSONValue] = [
                "place": .string(place), "weekday": .string(ForecastWeather.weekday(date) ?? ""),
                "source": .string(source), "day": "now", "now": nowBlock,
            ]
            if let entry { w["today"] = ForecastWeather.today(entry) }
            if let country { w["country"] = .string(country) }
            return .success(["weather": .object(w), "date": .string(date), "next": .string(ForecastWeather.nowNext)])
        }
        switch ForecastWeather.pick(days, day: nowView ? nil : parsed.day, date: parsed.date) {
        case .day(let entry):
            report(source, ok: true, reason: okReason, view: view)
            return .success(["weather": ForecastWeather.summary(entry, place: place, country: country, source: source),
                             "date": .string(entry.time), "next": .string(ForecastWeather.next)])
        case .past:
            report(source, ok: false, reason: "past", view: view)
            return .failure(.liveInfoUnavailable, advice: ForecastWeather.pastAdvice)
        case .notOut(let last):
            report(source, ok: false, reason: "not_out", view: view)
            return .failure(.liveInfoUnavailable, advice: ForecastWeather.notOutAdvice(last: last))
        case .missing:
            report(source, ok: false, reason: "no_day", view: view)
            return Self.failure(ForecastError.failed)
        }
    }

    /// §28 item 4: the hours of that part of that day on the place's clock.
    private func hoursResult(_ result: DailyForecast, source: String, part: String, place: String, country: String?,
                             _ parsed: ForecastWeather.Arguments, okReason: String = "ok") -> ToolResult {
        let placeNow = result.utcOffsetSeconds.map { ForecastWeather.placeClock(now(), utcOffsetSeconds: $0) }
            ?? result.current.flatMap { $0.time.isEmpty ? nil : $0.time }
        guard let todayText = placeNow.map({ String($0.prefix(10)) }) ?? result.days.first?.time ?? result.hours.first.map({ String($0.time.prefix(10)) }),
              let placeToday = ForecastWeather.isoDay(todayText) else {
            report(source, ok: false, reason: "no_day", view: "hours")
            return Self.failure(ForecastError.failed)
        }
        let date = parsed.date ?? ForecastWeather.adding(WeatherDay.names.firstIndex(of: parsed.day ?? "today") ?? 0, to: placeToday)
        switch ForecastWeather.hours(result.hours, part: part, date: date, placeNow: placeNow) {
        case .hours(let hours):
            report(source, ok: true, reason: okReason, view: "hours")
            var w: [String: JSONValue] = [
                "place": .string(place), "date": .string(date.iso), "weekday": .string(ForecastWeather.weekday(date.iso) ?? ""),
                "part": .string(part), "source": .string(source), "hours": ForecastWeather.hoursJSON(hours),
            ]
            if let country { w["country"] = .string(country) }
            return .success(["weather": .object(w), "date": .string(date.iso), "next": .string(ForecastWeather.hoursNext)])
        case .passed:
            report(source, ok: false, reason: "passed", view: "hours")
            return .failure(.liveInfoUnavailable, advice: ForecastWeather.partPassedAdvice)
        case .past:
            report(source, ok: false, reason: "past", view: "hours")
            return .failure(.liveInfoUnavailable, advice: ForecastWeather.pastAdvice)
        case .notOut(let last):
            report(source, ok: false, reason: "not_out", view: "hours")
            return .failure(.liveInfoUnavailable, advice: ForecastWeather.notOutAdvice(last: last))
        case .missing:
            report(source, ok: false, reason: "no_day", view: "hours")
            return Self.failure(ForecastError.failed)
        }
    }

    private func report(_ source: String, ok: Bool, reason: String, view: String) {
        let elapsed = Self.trace.map { ContinuousClock.now - $0.started }
        let ms = elapsed.map { Int($0.components.seconds) * 1000 + Int($0.components.attoseconds / 1_000_000_000_000_000) } ?? 0
        let tried = source == "open-meteo" ? max(1, ForecastAttempts.current?.last ?? 1) : 1
        onWeather(WeatherSourceLog(source: source, ok: ok, reason: reason, view: view, lookup: Self.trace?.lookup ?? "amap",
                                   attempts: tried, ms: ms))
    }

    static func reason(_ error: any Error) -> String {
        switch error {
        case let e as AmapWebError:
            switch e {
            case .keyMissing, .keyRejected: "key"
            case .quota: "quota"
            case .timeout: "timeout"
            case .failed: "failed"
            }
        case let e as QWeatherError: e.reason
        case ForecastError.timeout: "timeout"
        default: "failed"
        }
    }

    static func failure(_ error: any Error) -> ToolResult { LiveInfoFailure.result(error, what: "天气") }

    /// F-18 §23 item 2: no `casts` entry for the asked date.
    static let noForecastAdvice = "天气没有查到。请如实说明，不要编造。"

    /// F-18 §23 item 2: `day` → offset 0–3 and that day's `yyyy-MM-dd` on the phone clock. Anything else is today,
    /// as before.
    static func weatherDay(_ name: String?, now: Date, zone: TimeZone) -> WeatherDay {
        let offset = name.flatMap { WeatherDay.names.firstIndex(of: $0) } ?? 0
        let date = SearchDate.adding(offset, to: SearchDate.today(now, zone: zone), zone: zone)
        return WeatherDay(offset: offset, date: date.iso)
    }

    /// F-18 §23 item 3: search on, Amap's detail without opening hours fails with the search advice.
    static func searchFallback(_ result: ToolResult) -> ToolResult {
        guard result.ok, result.data["opening_hours"] == nil, let name = result.data["name"]?.stringValue else { return result }
        return .failure(.liveInfoUnavailable, advice: "高德没有\(name)的营业时间，请用 web_search 查，query 带上「\(name)」。")
    }

    // MARK: current_location

    /// F-16a 「我现在在哪？」: the regeo address of the same position search, weather and routing use.
    private func currentLocation() async -> ToolResult {
        if await location.authorization() == .denied { return Self.permissionDenied }
        guard let geocoder else {
            return .failure(.amapWebKeyMissing, advice: "高德的查询服务还没有配置，所以查不到地址。请如实说明，不要猜位置。")
        }
        guard let fix = await navigation.currentFix() else {
            return .failure(.noLocation, advice: "现在还没定位到。请如实说还没定位到，稍后再问；不要猜位置。")
        }
        do {
            guard let address = try await geocoder.address(at: fix.coordinate), !address.formatted.isEmpty else {
                return .failure(.noLocation, advice: "地址没有查到。请如实说明，不要猜位置。")
            }
            let demo = location.source == .demo
            var data: [String: JSONValue] = [
                "address": .string(Self.trimProvince(address.formatted)),
                "district": .string(address.district ?? ""),
                "accuracy_m": .int(Int64(fix.accuracyMeters.rounded())),
                "fix_age_s": .int(Int64(fix.ageSeconds)),
                "source": .string(location.source.rawValue),
                "next": .string(demo
                    ? "只按 address 用一句话回答，并说明这是演示起点，不是真实位置。不要编造。"
                    : "只按 address 用一句话回答（例如：你现在在……附近）。不要编造。"),
            ]
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

    /// F-16a §4: 「广东省珠海市香洲区…」 → 「珠海市香洲区…」. The province is dropped only when the address goes on
    /// with the city right after it; a municipality named twice (「北京市北京市朝阳区」) keeps one name. Anything
    /// else (no province, or no city right after it) is left as Amap wrote it.
    static func trimProvince(_ address: String) -> String {
        for marker in ["省", "自治区", "市"] {
            guard let range = address.range(of: marker) else { continue }
            let province = address[..<range.upperBound]
            let rest = address[range.upperBound...]
            if marker == "市" {
                // Municipality: province and city are the same name.
                return rest.hasPrefix(province) ? String(rest) : address
            }
            if rest.hasPrefix(province) { return String(rest) }
            guard let city = rest.firstIndex(where: { $0 == "市" || $0 == "州" || $0 == "盟" }) else { return address }
            let cityName = rest[..<city]
            // The city must follow directly: a short name, no district/county marker before it.
            let direct = !cityName.isEmpty && cityName.count <= 12
                && !cityName.contains(where: { "区县镇乡街路道号".contains($0) })
            return direct ? String(rest) : address
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
