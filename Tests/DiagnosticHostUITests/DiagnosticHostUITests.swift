import XCTest

final class DiagnosticHostUITests: XCTestCase {
    func testPrimarySectionsAndOverlayExpansion() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Memory Studio"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Increment sample Int32"].waitForExistence(timeout: 3))
        app.buttons["Expand diagnostic panel"].tap()
        XCTAssertTrue(app.buttons["Open scanner"].exists)
        app.buttons["Open scanner"].tap()
        XCTAssertTrue(app.navigationBars["Scanner"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Memory"].tap()
        XCTAssertTrue(app.navigationBars["Memory Viewer"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Files"].tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 3))
    }
}
