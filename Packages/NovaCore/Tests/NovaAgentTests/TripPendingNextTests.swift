import Testing
@testable import NovaAgent
@testable import NovaKit

@Suite("T-040ze F-15b §52 item 12 the turn's next while a trip tool runs")
struct TripPendingNextTests {
    @Test("T-040ze F-15b row 206 (unit): another result's next says 结果还没回来，不要说已经做好 while a trip tool runs")
    func next() {
        let r = AgentState.withTripPending(.success(["next": "用自己的话简短地说。"]))
        #expect(r.data["next"] == "用自己的话简短地说。；结果还没回来，不要说已经做好")
        #expect(AgentState.withTripPending(.success([:])).data["next"] == "结果还没回来，不要说已经做好")
    }
}
