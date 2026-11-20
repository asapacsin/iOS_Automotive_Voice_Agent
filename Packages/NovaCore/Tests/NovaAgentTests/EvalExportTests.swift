import Foundation
import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// F-09b §14 item 5: writes what `scripts/eval/ask_or_act.py` sends (the app's instruction, tools and session-start
/// notes for one setting) and the AskOrActEval cases, to the JSON file named by `EVAL_EXPORT`. No network, no key.
/// The same file is copied into an older checkout to export the baseline setup.
@Suite("F-09b §14 eval export")
struct EvalExportTests {
    static func setup(webSearch: Bool) -> [String: Any] {
        let instruction = PersonaInstruction.build(base: PersonaInstruction.base(PersonaInstruction.base, webSearch: webSearch),
                                                   style: .default)
        let tools: [[String: Any]] = ToolCatalog.declarations(webSearch: webSearch).map { t in
            let schema = (try? JSONSerialization.jsonObject(
                with: JSONValue.canonicalEncoder().encode(t.parametersJSONSchema))) ?? [:]
            return ["name": t.name, "description": t.description, "parameters": schema]
        }
        let car = CarStateSnapshot(acOn: true, temperatureC: 24, fanLevel: 2, windows: [:], driverSeat: 3,
                                   musicPlaying: false, speedKmh: 60).note
        let now = ContextSnapshot(place: ContextPlace(city: "珠海市", district: "香洲区"), onHighway: nil,
                                  localTime: "14:30").note
        return ["instruction": instruction, "tools": tools, "notes": [car, now]]
    }

    static func expect(_ e: AskOrActEval.Expect) -> [String: Any] {
        switch e {
        case .act(let tools): ["kind": "act", "tools": tools.sorted()]
        case .offer: ["kind": "offer"]
        case .answer: ["kind": "answer"]
        case .goes: ["kind": "goes"]
        }
    }

    @Test("export the eval setup and cases when EVAL_EXPORT is set")
    func export() throws {
        guard let path = ProcessInfo.processInfo.environment["EVAL_EXPORT"] else { return }
        let cases: [[String: Any]] = AskOrActEval.cases.map { c in
            ["id": c.id, "group": c.group.rawValue,
             "history": c.history.map { ["role": $0.role == .user ? "user" : "model", "text": $0.text] },
             "turns": c.turns.map { ["said": $0.said, "expect": Self.expect($0.expect)] }]
        }
        let object: [String: Any] = ["search": Self.setup(webSearch: true), "nosearch": Self.setup(webSearch: false),
                                     "readOnly": AskOrActEval.readOnly.sorted(), "cases": cases]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: path))
    }
}
