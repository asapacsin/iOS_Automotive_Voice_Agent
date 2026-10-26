import XCTest

/// T-048 (W8 in UI): search → pick → route → navigate on the 驾驶 screen in the simulator, with the
/// scripted search and engine (`-uitest-scripted-drive`), so no keys, microphone or network are needed.
final class DriveFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSearchPickRouteNavigate() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-scripted-drive"]
        app.launch()
        func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

        let navigate = element("uitest-navigate")
        XCTAssertTrue(navigate.waitForExistence(timeout: 20))
        navigate.tap()

        // Destination list: two candidates.
        let place = element("place-row-0")
        XCTAssertTrue(place.waitForExistence(timeout: 10))
        XCTAssertTrue(element("place-row-1").exists)
        XCTAssertFalse(element("hud-panel").exists)
        place.tap()

        // Route list after the pick; no guidance yet.
        let route = element("route-row-0")
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        XCTAssertTrue(element("route-row-1").exists)
        XCTAssertFalse(element("place-row-0").exists)
        XCTAssertFalse(element("hud-panel").exists)
        route.tap()

        // Guidance started: the HUD shows the destination and the lists are gone.
        XCTAssertTrue(element("hud-panel").waitForExistence(timeout: 10))
        XCTAssertFalse(element("route-row-0").exists)
        XCTAssertTrue(app.staticTexts["珠海站"].exists)
    }
}
