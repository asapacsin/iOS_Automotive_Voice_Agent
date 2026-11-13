import Testing
import NovaKit
import NovaVoice
@testable import NovaAgent

@Suite("T-046s F-18 §30 weather record line")
struct WeatherRecordTests {
    @Test("T-046s F-18 §30 row 06: the weather line goes to the record as it is")
    func recordLine() {
        var recorder = ConversationRecorder()
        let line = "weather source=open-meteo ok=yes reason=ok view=day lookup=open-meteo attempts=2 ms=5120"
        #expect(recorder.add(.weather(line), atMs: 42) == ["42 " + line])
    }
}
