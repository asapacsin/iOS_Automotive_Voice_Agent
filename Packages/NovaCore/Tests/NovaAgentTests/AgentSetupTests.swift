import Foundation
import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// F-09b §15 (T-031y). `AGENT_SETUP_WRITE=1` writes specs/contracts/agent-setup-parts/<version>.json for a new
/// version (never over an existing file).
enum AgentRegistry {
    static func root(_ file: String = #filePath) -> URL {
        var u = URL(fileURLWithPath: file)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }

    /// `| version | setupHash | ...` rows of specs/contracts/agent-versions.md, newest first.
    static func rows(_ text: String) -> [(version: String, hash: String)] {
        text.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2, cells[0].range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
            return (cells[0], cells[1])
        }
    }

    /// Item 5: nil when the registry row for `version` has `hash`.
    static func check(hash: String, version: String, registry: String) -> String? {
        rows(registry).first { $0.version == version }?.hash == hash ? nil : "agent setup changed: add a version row"
    }

    static func partsJSON() throws -> Data {
        var parts: [String: String] = [:]
        for p in AgentSetup.combined() { parts[p.name] = p.text }
        var sessions: [String: String] = [:]
        for s in AgentSetup.Settings.all { sessions[s.label] = AgentSetup(s).hash }
        let object: [String: Any] = ["version": AgentSetup.version, "setupHash": AgentSetup.setupHash,
                                     "sessions": sessions, "parts": parts]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }
}

@Suite("T-031y F-09b §15 agent setup version")
struct AgentSetupTests {
    @Test("T-031y F-09b §15 row 1: parts in item 1's order for every setting; no audio, UI or key parts")
    func row1() {
        #expect(AgentSetup.Settings.all.count == SpeakingStyle.allCases.count * 2)
        for s in AgentSetup.Settings.all {
            let names = AgentSetup(s).parts.map(\.name)
            let rank: (String) -> Int = { n in
                ["model", "base.", "tool.", "note.", "tuning."].firstIndex { n == $0 || n.hasPrefix($0) } ?? 99
            }
            #expect(names.first == "model")
            #expect(names.map(rank) == names.map(rank).sorted(), "\(s.label)")
            #expect(!names.contains { $0.contains("audio") || $0.contains("key") || $0.contains("ui.") })
            #expect(names.contains("base.\(s.label)"))
            #expect(names.contains { $0.hasPrefix("note.now") } && names.contains { $0.hasPrefix("note.tripArrived") })
            #expect(names.contains("tool.search.web_search.description") == s.webSearch)
        }
        #expect(SHA256Digest.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256Digest.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256Digest.hex(String(repeating: "a", count: 1000)).hasPrefix("41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3".prefix(8)))
    }

    @Test("T-031y F-09b §15 rows 2-3: the registry row matches the setup; one changed character fails until a row is added")
    func row2() throws {
        let registry = try String(contentsOf: AgentRegistry.root().appendingPathComponent("specs/contracts/agent-versions.md"),
                                  encoding: .utf8)
        #expect(AgentRegistry.rows(registry).first?.version == AgentSetup.version, "newest row is AgentSetup.version")
        #expect(AgentRegistry.check(hash: AgentSetup.setupHash, version: AgentSetup.version, registry: registry) == nil,
                "agent setup changed: add a version row (now \(AgentSetup.setupHash))")
        var parts = AgentSetup.combined()
        let i = try #require(parts.firstIndex { $0.name.hasSuffix(".description") })
        parts[i] = AgentSetup.Part(name: parts[i].name, text: parts[i].text + "。")
        let changed = AgentSetup.hash(parts)
        #expect(changed != AgentSetup.setupHash)
        #expect(AgentRegistry.check(hash: changed, version: AgentSetup.version, registry: registry)
                == "agent setup changed: add a version row")
        let bumped = "| 1.1.0 | \(changed) | 2026-11-20 | x | minor: one description | F-09b §15 |\n" + registry
        #expect(AgentRegistry.check(hash: changed, version: "1.1.0", registry: bumped) == nil)

        // The parts file of this version is what the gate compares (written once, then must match).
        let url = AgentRegistry.root().appendingPathComponent("specs/contracts/agent-setup-parts/\(AgentSetup.version).json")
        let json = try AgentRegistry.partsJSON()
        if ProcessInfo.processInfo.environment["AGENT_SETUP_WRITE"] == "1", !FileManager.default.fileExists(atPath: url.path) {
            try json.write(to: url)
        }
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary
        let now = try JSONSerialization.jsonObject(with: json) as? NSDictionary
        #expect(stored == now, "agent-setup-parts/\(AgentSetup.version).json is stale")
    }

    @Test("T-031y F-09b §15 row 5: AgentSetup.tuning names equal the // agentSetup marks in Tuning.swift")
    func row5() throws {
        let tuning = try String(contentsOf: AgentRegistry.root().appendingPathComponent("Packages/NovaCore/Sources/NovaKit/Tuning.swift"),
                                encoding: .utf8)
        let marked = tuning.split(separator: "\n").filter { $0.contains("// agentSetup") }.compactMap { line -> String? in
            guard let r = line.range(of: #"static (let|var) (\w+)"#, options: .regularExpression) else { return nil }
            return String(line[r].split(separator: " ").last!)
        }
        #expect(Set(marked) == Set(AgentSetup.tuning.map(\.0)))
    }

    @Test("T-031y F-09b §15 row 6: header lines and log line for the session's settings; the log has no text")
    func row6() {
        let a = AgentSetup(.init(style: .default, webSearch: false))
        let b = AgentSetup(.init(style: .sweet, webSearch: false))
        #expect(a.hash != b.hash && a.hash.count == 12)
        #expect(a.headerLines() == ["agentVersion \(AgentSetup.version)", "agentHash \(a.hash)", "model gemini-3.8-live"])
        #expect(a.logLine() == "agent version=\(AgentSetup.version) hash=\(a.hash) model=gemini-3.8-live")
        #expect(!a.logLine().unicodeScalars.contains { $0.value > 0x7f })
        let record = ConversationRecord.make(enabled: true, header: RecordHeader(
            appVersion: "0.1.0(1) abcdef0", comfortMode: "model", interruptible: false, speakingStyle: "default",
            agentLines: a.headerLines()))!
        let w = MemoryWriter()
        record.drain(to: w)
        #expect(Array(w.lines.withLock { $0 }.prefix(5)) == ["recordFormat 4", "app 0.1.0(1) abcdef0"] + a.headerLines())
    }
}
