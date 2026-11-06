import XCTest

final class DiagnosticHostUITests: XCTestCase {
    func testHostRegistersOwnedDataAndNavigates() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Recovery workspace"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["host-owned-values"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Scan"].tap()
        XCTAssertTrue(app.navigationBars["Scanner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start scan"].exists)
        app.tabBars.buttons["Memory"].tap()
        XCTAssertTrue(app.navigationBars["Memory map"].waitForExistence(timeout: 5))
    }

    func testOverlayExpandsInsideHost() throws {
        let app = XCUIApplication()
        app.launch()
        let expand = app.buttons["Expand overlay"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        XCTAssertTrue(app.staticTexts["APP-OWNED REGIONS ONLY"].waitForExistence(timeout: 3))
    }
}