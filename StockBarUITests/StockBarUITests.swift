import XCTest

class StockBarUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        app.launch()
        continueAfterFailure = false
    }

    func testPreferencePopover() throws {
        // Test opening preferences
        let statusBarItem = app.statusItems["StockBar"]
        statusBarItem.click()

        let preferencesButton = app.menuItems["Preference"]
        preferencesButton.click()

        // Verify preference window appears
        let prefsWindow = app.windows["Preferences"]
        XCTAssertTrue(prefsWindow.exists)
    }

    func testAddNewSymbol() throws {
        // Open preferences
        let statusBarItem = app.statusItems["StockBar"]
        statusBarItem.click()

        let preferencesButton = app.menuItems["Preference"]
        preferencesButton.click()

        // Add new symbol
        let addButton = app.buttons["Add Symbol"]
        addButton.click()

        let symbolTextField = app.textFields["Symbol"]
        symbolTextField.typeText("AAPL")

        // Verify symbol appears in list
        XCTAssertTrue(app.tables.cells.containing(NSPredicate(format: "label CONTAINS 'AAPL'")).exists)
    }

    func testRefreshStocks() throws {
        // Click the menu bar item
        let statusBarItem = app.statusItems["StockBar"]
        statusBarItem.click()

        // Click refresh
        let refreshButton = app.menuItems["Refresh"]
        refreshButton.click()

        // Verify refresh occurred (you might need to adjust this based on your UI feedback)
        // For example, if you have a loading indicator:
        // XCTAssertTrue(app.activityIndicators["RefreshingStocks"].exists)
    }
}
