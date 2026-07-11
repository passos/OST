import XCTest

final class OSTUITests: XCTestCase {
    func testMenuBarAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertNotEqual(app.state, .notRunning)
    }
}
