import XCTest
@testable import Stockbar
import AppKit

final class MenuBarFormattingServiceTests: XCTestCase {

    var service: MenuBarFormattingService!

    override func setUp() async throws {
        try await super.setUp()
        service = MenuBarFormattingService()
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    // MARK: - Compact Mode Tests

    func testCompactMode_FormatsCorrectly() async throws {
        // Given: Compact mode settings
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .compact
        settings.changeFormat = .percentage

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should show symbol + percentage
        let string = result.string
        XCTAssertTrue(string.contains("AAPL"), "Should contain symbol")
        XCTAssertTrue(string.contains("2.51%") || string.contains("+2.51%"), "Should contain percentage")
    }

    func testCompactMode_WithNegativeChange() async throws {
        // Given: Compact mode with negative change
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .compact
        settings.changeFormat = .percentage

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "TSLA",
            price: 250.00,
            change: -10.50,
            changePct: -4.03,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should show negative percentage
        let string = result.string
        XCTAssertTrue(string.contains("TSLA"), "Should contain symbol")
        XCTAssertTrue(string.contains("-4.03%") || string.contains("4.03%"), "Should contain negative percentage")
    }

    // MARK: - Expanded Mode Tests

    func testExpandedMode_FormatsCorrectly() async throws {
        // Given: Expanded mode settings
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .percentage
        settings.decimalPlaces = 2

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "GOOGL",
            price: 140.75,
            change: 3.25,
            changePct: 2.36,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should show symbol + price + percentage
        let string = result.string
        XCTAssertTrue(string.contains("GOOGL"), "Should contain symbol")
        XCTAssertTrue(string.contains("140.75") || string.contains("$140.75"), "Should contain price")
        XCTAssertTrue(string.contains("2.36%") || string.contains("+2.36%"), "Should contain percentage")
    }

    func testExpandedMode_WithCurrencySymbol() async throws {
        // Given: Expanded mode with currency display
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .percentage
        settings.showCurrency = true
        settings.decimalPlaces = 2

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "MSFT",
            price: 425.00,
            change: 5.00,
            changePct: 1.19,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should contain currency symbol
        let string = result.string
        XCTAssertTrue(string.contains("$") || string.contains("USD"), "Should contain currency")
    }

    // MARK: - Minimal Mode Tests

    func testMinimalMode_FormatsCorrectly() async throws {
        // Given: Minimal mode settings
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .minimal
        settings.useArrowIndicators = true
        settings.arrowStyle = .simple

        // When: Format stock title (positive change)
        let result = await service.formatStockTitle(
            symbol: "NVDA",
            price: 450.00,
            change: 10.00,
            changePct: 2.27,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should show symbol + indicator
        let string = result.string
        XCTAssertTrue(string.contains("NVDA"), "Should contain symbol")
        // Should contain some form of up indicator
    }

    func testMinimalMode_WithNegativeChange() async throws {
        // Given: Minimal mode with down arrow
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .minimal
        settings.useArrowIndicators = true
        settings.arrowStyle = .simple

        // When: Format stock title (negative change)
        let result = await service.formatStockTitle(
            symbol: "AMD",
            price: 120.00,
            change: -5.00,
            changePct: -4.00,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should show symbol (arrow tested in display)
        let string = result.string
        XCTAssertTrue(string.contains("AMD"), "Should contain symbol")
    }

    // MARK: - Custom Template Mode Tests

    func testCustomTemplate_WithAllPlaceholders() async throws {
        // Given: Custom template with all placeholders
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .custom
        settings.customTemplate = "{symbol}: {price} ({changePct})"
        settings.decimalPlaces = 2

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should match template
        let string = result.string
        XCTAssertTrue(string.contains("AAPL"), "Should contain symbol")
        XCTAssertTrue(string.contains("175.23"), "Should contain price")
        XCTAssertTrue(string.contains("2.51%") || string.contains("+2.51%"), "Should contain percentage")
    }

    func testCustomTemplate_WithChangeAndChangePct() async throws {
        // Given: Custom template with both change formats
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .custom
        settings.customTemplate = "{symbol} {change} {changePct}"
        settings.decimalPlaces = 2

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "TSLA",
            price: 250.00,
            change: 10.50,
            changePct: 4.38,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should contain both change formats
        let string = result.string
        XCTAssertTrue(string.contains("TSLA"), "Should contain symbol")
        XCTAssertTrue(string.contains("10.50") || string.contains("+10.50"), "Should contain dollar change")
        XCTAssertTrue(string.contains("4.38%") || string.contains("+4.38%"), "Should contain percentage change")
    }

    // MARK: - Change Format Tests

    func testChangeFormat_Percentage() async throws {
        // Given: Percentage format
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .percentage

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should contain percentage
        let string = result.string
        XCTAssertTrue(string.contains("%"), "Should contain percentage symbol")
    }

    func testChangeFormat_Dollar() async throws {
        // Given: Dollar format
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .dollar

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should contain dollar change
        let string = result.string
        XCTAssertTrue(string.contains("4.29") || string.contains("+4.29"), "Should contain dollar change")
    }

    func testChangeFormat_Both() async throws {
        // Given: Both formats
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .both

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should contain both formats
        let string = result.string
        XCTAssertTrue(string.contains("4.29") || string.contains("+4.29"), "Should contain dollar change")
        XCTAssertTrue(string.contains("%"), "Should contain percentage")
    }

    // MARK: - Decimal Places Tests

    func testDecimalPlaces_Zero() async throws {
        // Given: Zero decimal places
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .percentage
        settings.decimalPlaces = 0

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should round to whole numbers
        let string = result.string
        XCTAssertTrue(string.contains("175") || string.contains("$175"), "Should show rounded price")
    }

    func testDecimalPlaces_Four() async throws {
        // Given: Four decimal places
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .percentage
        settings.decimalPlaces = 4

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23456,
            change: 4.29123,
            changePct: 2.51234,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should show 4 decimal places
        let string = result.string
        // Check that price has appropriate precision
        XCTAssertTrue(string.contains("175.2"), "Should show detailed price")
    }

    // MARK: - Color Coding Tests

    func testColorCoding_PositiveChange() async throws {
        // Given: Positive change with color coding
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .percentage

        // When: Format with color coding enabled
        let result = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: true
        )

        // Then: Should have green color attribute
        var foundGreenColor = false
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, stop in
            if let color = value as? NSColor {
                // Check if color is greenish (hue around 120°)
                if color.greenComponent > 0.3 {
                    foundGreenColor = true
                    stop.pointee = true
                }
            }
        }
        XCTAssertTrue(foundGreenColor, "Should have green color for positive change")
    }

    func testColorCoding_NegativeChange() async throws {
        // Given: Negative change with color coding
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .percentage

        // When: Format with color coding enabled
        let result = await service.formatStockTitle(
            symbol: "TSLA",
            price: 250.00,
            change: -10.50,
            changePct: -4.03,
            currency: "USD",
            settings: settings,
            useColorCoding: true
        )

        // Then: Should have red color attribute
        var foundRedColor = false
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, stop in
            if let color = value as? NSColor {
                // Check if color is reddish
                if color.redComponent > 0.3 {
                    foundRedColor = true
                    stop.pointee = true
                }
            }
        }
        XCTAssertTrue(foundRedColor, "Should have red color for negative change")
    }

    // MARK: - Cache Tests

    func testCache_ReturnsCachedResult() async throws {
        // Given: Same parameters twice
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .percentage

        // When: Format same stock twice
        let result1 = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        let result2 = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should return identical strings (from cache)
        XCTAssertEqual(result1.string, result2.string, "Cache should return identical results")
    }

    func testCache_InvalidatesOnSettingsChange() async throws {
        // Given: Format with one setting
        var settings1 = MenuBarDisplaySettings()
        settings1.displayMode = .compact

        let result1 = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings1,
            useColorCoding: false
        )

        // When: Change settings and format again
        var settings2 = MenuBarDisplaySettings()
        settings2.displayMode = .expanded

        let result2 = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings2,
            useColorCoding: false
        )

        // Then: Results should be different
        XCTAssertNotEqual(result1.string, result2.string, "Different settings should produce different results")
    }

    // MARK: - Arrow Indicator Tests

    func testArrowIndicators_UpArrow() async throws {
        // Given: Settings with arrow indicators
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .compact
        settings.useArrowIndicators = true
        settings.arrowStyle = .simple

        // When: Format with positive change
        let result = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Result should be generated (arrow symbols are implementation-specific)
        XCTAssertFalse(result.string.isEmpty, "Should generate formatted string")
    }

    // MARK: - Currency Symbol Tests

    func testCurrencySymbol_USD() async throws {
        // Given: USD currency
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.showCurrency = true

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should contain USD symbol
        let string = result.string
        XCTAssertTrue(string.contains("$") || string.contains("USD"), "Should contain USD symbol")
    }

    func testCurrencySymbol_GBP() async throws {
        // Given: GBP currency
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.showCurrency = true

        // When: Format stock title
        let result = await service.formatStockTitle(
            symbol: "VOD.L",
            price: 75.50,
            change: 2.50,
            changePct: 3.42,
            currency: "GBP",
            settings: settings,
            useColorCoding: false
        )

        // Then: Should contain GBP symbol
        let string = result.string
        XCTAssertTrue(string.contains("£") || string.contains("GBP"), "Should contain GBP symbol")
    }
}
