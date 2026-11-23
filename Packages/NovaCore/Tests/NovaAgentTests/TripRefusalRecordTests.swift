import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaPorts

@Suite("T-040zi F-15b §56 item 6 record lines of a refused set_trip_plan")
struct TripRefusalRecordTests {
    @Test("T-040zi F-15b row 242: record: INVALID_FIELDS problems=<n> (the count, never the lines); a REPEATED_FAILURE adds trip repeat-blocked code=<code>")
    func row242Record() {
        var r = ConversationRecorder()
        let problems: JSONValue = ["第1天第1个地点：role 只能是 start、sight、hotel、end、rental_pickup、rental_return", "新行程要写 city"]
        let refused = r.add(.toolResult(name: "set_trip_plan", ok: false, code: "INVALID_FIELDS",
                                        data: ["problems": problems, "changed": false]), atMs: 10)
        #expect(refused.count == 1 && refused[0].hasPrefix("10 tool-result set_trip_plan ok=false code=INVALID_FIELDS problems=2 "), "\(refused)")
        #expect(!refused[0].contains("role 只能是"))
        let blocked = r.add(.toolResult(name: "set_trip_plan", ok: false, code: "REPEATED_FAILURE",
                                        data: ["problems": problems, "refused_code": "INVALID_FIELDS"]), atMs: 20)
        #expect(blocked.count == 2 && blocked[0].contains("code=REPEATED_FAILURE problems=2"))
        #expect(blocked[1] == "20 trip repeat-blocked code=INVALID_FIELDS")
    }

    @Test("T-040zi F-15b row 243: agent version bumped (minor) for the §56 item 5 catalog text")
    func row243Version() {
        #expect(AgentSetup.version == "6.1.0")
    }
}
