import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaAgent
@testable import NovaTools

private final class Keys: CredentialStore, @unchecked Sendable {
    let values = Mutex<[CredentialKey: String]>([:])
    func value(for key: CredentialKey) throws -> String? { values.withLock { $0[key] } }
    func set(_ value: String, for key: CredentialKey) throws { values.withLock { $0[key] = value } }
    func remove(_ key: CredentialKey) throws { values.withLock { $0[key] = nil } }
    func removeRetired(account: String) throws {}
}

private final class NoSettings: SettingsStore {
    func string(_ key: String) -> String? { nil }
    func bool(_ key: String) -> Bool? { nil }
    func set(_ value: String?, for key: String) {}
    func set(_ value: Bool, for key: String) {}
}

@Suite("T-046t F-18 §31 10-day texts and 和风 keys")
struct QWeatherTextTests {
    /// 2026-11-13 12:00 in Asia/Shanghai.
    static let now = Date(timeIntervalSince1970: 1_794_542_400)
    static let zone = TimeZone(identifier: "Asia/Shanghai")!

    @Test("T-046t F-18 §31 row 07: 10-day texts with no 16天 left; base within the limit; 11-22 blocked, 11-23 goes to Qwen")
    func row07() {
        let texts = [ToolCatalog.weatherPart, ToolCatalog.officialFirst, ToolCatalog.webSearchSpec.declaration.description,
                     PersonaInstruction.webSearchSentence, WeatherForecastQuery.advice]
        for text in texts {
            #expect(!text.contains("16天") && text.contains("10天内"), "\(text)")
        }
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            for search in [false, true] {
                let text = PersonaInstruction.base(PersonaInstruction.base(for: mode), webSearch: search)
                #expect(text.count <= PersonaInstruction.maxBaseCharacters && !text.contains("16天"))
            }
        }
        #expect(WeatherForecastQuery.matches("上海11月22日天气", now: Self.now, zone: Self.zone))
        #expect(!WeatherForecastQuery.matches("上海11月23日天气", now: Self.now, zone: Self.zone))
    }

    @Test("T-046t F-18 §31 item 1: the host is saved without https:// and /; readiness needs host and key")
    func keys() throws {
        let store = Keys()
        #expect(try SecretField.save(" https://abc123.qweatherapi.com/ ", for: .qweatherHost, in: store))
        #expect(try store.value(for: .qweatherHost) == "abc123.qweatherapi.com")
        #expect(!SettingsReadiness(credentials: store, settings: NoSettings()).qweather)
        _ = try SecretField.save("k1", for: .qweatherKey, in: store)
        #expect(SettingsReadiness(credentials: store, settings: NoSettings()).qweather)
        #expect(CredentialKey.qweatherHost.rawValue == "qweather_host" && CredentialKey.qweatherKey.rawValue == "qweather_key")
        #expect(QWeatherHost.normalized("http://x.qweatherapi.com//") == "x.qweatherapi.com")
    }
}
