import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaRealtime

private func place(_ name: String, _ address: String?) -> Place {
    Place(id: name, name: name, address: address, coordinate: GeoCoordinate(latitude: 39.9, longitude: 116.4, datum: .gcj02),
          distanceMeters: nil, district: "东城区")
}

/// F-15b §4 item 6 row 47 (owner 2026-11-17).
@Suite("F-15b row 47 QwenPlacePicker")
struct PlacePickerTests {
    let choices = [
        PlaceChoice(asked: "北京故宫", city: "北京", candidates: [place("北京故宫博物院北院区(建设中)", "海淀区"), place("故宫博物院", "景山前街4号")]),
        PlaceChoice(asked: "路环那家葡挞", city: nil, candidates: [place("不是葡挞", nil), place("路环岛", nil)]),
    ]

    @Test("T-040zl F-15b row 259: request: qwen3.8-flash, search and thinking off, EntGPT instruction, numbered candidates with None; key in the header only")
    func request() throws {
        let r = QwenPlacePicker(key: { "k" }).request(choices, key: "k")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let body = try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data())
        #expect(body["model"] == "qwen3.8-flash" && body["parameters"]?["incremental_output"] == nil)
        #expect(QwenRoute.picker.chain.count == 1)  // F-18 §36: one evaluated picker model until row 35
        #expect(body["parameters"]?["enable_search"] == false && body["parameters"]?["enable_thinking"] == false)
        let text = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
        #expect(!text.contains("\"k\""))
        let q = QwenPlacePicker.question(choices)
        #expect(QwenPlacePicker.instruction == "Select the entity which best describes the mention.")
        #expect(q.contains("Mention 1: 北京故宫 (city: 北京)") && q.contains("(2) 故宫博物院 — 景山前街4号, 东城区"))
        #expect(q.contains("Mention 2: 路环那家葡挞\n(1) 不是葡挞 — 东城区") && q.contains("(0) None of the above"))
    }

    @Test("Answer: lines parsed, 0 is none, out of range or missing is unreadable; no key throws")
    func answers() async throws {
        #expect(try QwenPlacePicker.answers("1: 2\n2：0", choices: choices) == [1, nil])
        #expect(throws: QwenPlacePicker.PickError.unreadable) { try QwenPlacePicker.answers("1: 3\n2: 1", choices: choices) }
        #expect(throws: QwenPlacePicker.PickError.unreadable) { try QwenPlacePicker.answers("1: 2", choices: choices) }
        let reply = Data(#"{"output":{"choices":[{"message":{"content":[{"text":"1: 2\n2: 0"}]}}]}}"#.utf8)
        let picker = QwenPlacePicker(key: { "k" }, send: { _ in (200, reply) })
        #expect(try await picker.pick(choices) == [1, nil])
        await #expect(throws: PlacePickerNotConfigured.self) { try await QwenPlacePicker(key: { nil }).pick(choices) }
        await #expect(throws: QwenPlacePicker.PickError.http(500)) {
            try await QwenPlacePicker(key: { "k" }, send: { _ in (500, Data()) }).pick(choices)
        }
    }
}
