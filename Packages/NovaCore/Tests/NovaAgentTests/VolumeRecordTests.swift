import Testing
import NovaKit
import NovaVoice
@testable import NovaAgent

@Suite("T-032g F-13a volume record and claims")
struct VolumeRecordTests {
    @Test("F-13a §7: the volume line goes to the record as it is")
    func recordLine() {
        var recorder = ConversationRecorder()
        let line = "volume set target=media from=6 to=8 by=tool limit=false"
        #expect(recorder.add(.volume(line), atMs: 42) == ["42 " + line])
    }

    @Test("F-13a §4 item 5: a media set_volume result backs a claim about the music's volume; a voice one does not")
    func claimProof() {
        let media: [String: JSONValue] = ["target": "media", "level": .int(6)]
        let voice: [String: JSONValue] = ["target": "voice", "level": .int(6)]
        #expect(ClaimLexicon.unbackedTopics(in: "音乐音量已调到6", proofs: [("set_volume", media)]).isEmpty)
        #expect(ClaimLexicon.unbackedTopics(in: "音乐音量已调到6", proofs: [("set_volume", voice)]) == [.music])
        // The code-built announce claims nothing the gate has to prove.
        #expect(ClaimLexicon.claims(in: "音乐音量调到 6 了").isEmpty)
        #expect(ClaimLexicon.claims(in: "我说话的声音调到 8 了").isEmpty)
    }
}
