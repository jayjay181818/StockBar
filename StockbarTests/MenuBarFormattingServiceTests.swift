import XCTest
@testable import Stockbar
import AppKit
import Combine

private extension MenuBarFormattingService {
    func formatStockTitle(
        symbol: String,
        price: Double,
        change: Double,
        changePct: Double,
        currency: String,
        settings: MenuBarDisplaySettings,
        useColorCoding: Bool
    ) -> NSAttributedString {
        formatStockTitle(
            symbol: symbol,
            price: price,
            change: change,
            changePct: changePct,
            dayPL: change,
            currency: currency,
            settings: settings,
            useColorCoding: useColorCoding
        )
    }
}

private extension NSColor {
    var isGreenishForTest: Bool {
        if isEqual(NSColor.systemGreen) { return true }
        guard let rgbColor = usingColorSpace(.sRGB) ?? usingColorSpace(.deviceRGB) else {
            return false
        }
        return rgbColor.greenComponent > rgbColor.redComponent
            && rgbColor.greenComponent > rgbColor.blueComponent
    }

    var isReddishForTest: Bool {
        if isEqual(NSColor.systemRed) { return true }
        guard let rgbColor = usingColorSpace(.sRGB) ?? usingColorSpace(.deviceRGB) else {
            return false
        }
        return rgbColor.redComponent > rgbColor.greenComponent
            && rgbColor.redComponent > rgbColor.blueComponent
    }
}

@MainActor
final class MenuBarFormattingServiceTests: XCTestCase {

    // XCTest makes one instance of the class per test, so each test gets a
    // formatter with an empty cache.
    private let service = MenuBarFormattingService()

    func testMenuBarSymbolPresentationUsesTickerInsteadOfFolyncDisplayLabel() {
        XCTAssertEqual(MenuBarSymbolPresentation.title(for: " CARD.L "), "CARD.L")
    }

    func testMenuBarContentUpdatesPreserveInitialEventAndLaterContentChanges() {
        let contentChanges = PassthroughSubject<Void, Never>()
        var receivedEventCount = 0
        var cancellables = Set<AnyCancellable>()

        MenuBarContentUpdates.effectiveContentPublisher(contentChanges)
            .sink { _ in receivedEventCount += 1 }
            .store(in: &cancellables)

        XCTAssertEqual(receivedEventCount, 1)

        contentChanges.send(())
        contentChanges.send(())

        XCTAssertEqual(receivedEventCount, 3)
    }

    func testMenuPriceChangeCalculatorUsesRollingDayBaselineWhenHistoryExists() {
        let summary = MenuPriceChangeCalculator.rollingDaySummary(
            currentPrice: 8.02,
            previousClose: 8.72,
            units: 275,
            historicalPrices: [5.77, 6.10, 8.02],
            symbol: "ATAI"
        )

        XCTAssertEqual(summary.change, 2.25, accuracy: 0.0001)
        XCTAssertEqual(summary.percent, 38.9948, accuracy: 0.0001)
        XCTAssertEqual(summary.positionPnL, 618.75, accuracy: 0.0001)
    }

    func testMenuPriceChangeCalculatorFallsBackToPreviousCloseWithoutHistory() {
        let summary = MenuPriceChangeCalculator.rollingDaySummary(
            currentPrice: 8.02,
            previousClose: 8.72,
            units: 275,
            historicalPrices: [],
            symbol: "ATAI"
        )

        XCTAssertEqual(summary.change, -0.70, accuracy: 0.0001)
        XCTAssertEqual(summary.percent, -8.0275, accuracy: 0.0001)
        XCTAssertEqual(summary.positionPnL, -192.50, accuracy: 0.0001)
    }

    func testMenuPriceChangeCalculatorNormalizesLegacyUKPenceHistory() {
        let summary = MenuPriceChangeCalculator.rollingDaySummary(
            currentPrice: 0.82,
            previousClose: 0.80,
            units: 100,
            historicalPrices: [79.60, 81.00],
            symbol: "TW.L"
        )

        XCTAssertEqual(summary.change, 0.024, accuracy: 0.0001)
        XCTAssertEqual(summary.percent, 3.0151, accuracy: 0.0001)
        XCTAssertEqual(summary.positionPnL, 2.40, accuracy: 0.0001)
    }

    // MARK: - Visibility Policy Tests

    func testMenuBarVisibilityPolicy_ManualOffAlwaysHidesStockTickers() {
        XCTAssertFalse(
            MenuBarVisibilityPolicy.shouldShowStockItems(
                hideAllMenuBarItems: true,
                requireExternalDisplay: false,
                isExternalDisplayConnected: true
            )
        )
        XCTAssertFalse(
            MenuBarVisibilityPolicy.shouldShowStockItems(
                hideAllMenuBarItems: true,
                requireExternalDisplay: true,
                isExternalDisplayConnected: true
            )
        )
    }

    func testMenuBarVisibilityPolicy_ExternalDisplayRuleOffPreservesManualVisibility() {
        XCTAssertTrue(
            MenuBarVisibilityPolicy.shouldShowStockItems(
                hideAllMenuBarItems: false,
                requireExternalDisplay: false,
                isExternalDisplayConnected: false
            )
        )
    }

    func testMenuBarVisibilityPolicy_ExternalDisplayRuleHidesWithoutExternalDisplay() {
        XCTAssertFalse(
            MenuBarVisibilityPolicy.shouldShowStockItems(
                hideAllMenuBarItems: false,
                requireExternalDisplay: true,
                isExternalDisplayConnected: false
            )
        )
    }

    func testMenuBarVisibilityPolicy_ExternalDisplayRuleRestoresWithExternalDisplay() {
        XCTAssertTrue(
            MenuBarVisibilityPolicy.shouldShowStockItems(
                hideAllMenuBarItems: false,
                requireExternalDisplay: true,
                isExternalDisplayConnected: true
            )
        )
    }

    func testMenuBarVisibilityPolicy_DoesNotControlPortfolioTotalSetting() {
        let portfolioSettings = PortfolioMenuBarDisplaySettings(isEnabled: true)

        XCTAssertTrue(portfolioSettings.isEnabled)
        XCTAssertFalse(
            MenuBarVisibilityPolicy.shouldShowStockItems(
                hideAllMenuBarItems: false,
                requireExternalDisplay: true,
                isExternalDisplayConnected: false
            )
        )
    }

    func testMenuBarVisibilityPolicy_PersistsExternalDisplayRequirement() {
        let suiteName = TestDefaultsSuite.makeName("MenuBarVisibilityPolicyTests.")
        let defaults = UserDefaults(suiteName: suiteName)!
        TestDefaultsSuite.remove(suiteName)

        XCTAssertFalse(MenuBarVisibilityPolicy.loadRequireExternalDisplay(defaults: defaults))

        MenuBarVisibilityPolicy.saveRequireExternalDisplay(true, defaults: defaults)
        XCTAssertTrue(MenuBarVisibilityPolicy.loadRequireExternalDisplay(defaults: defaults))

        MenuBarVisibilityPolicy.saveRequireExternalDisplay(false, defaults: defaults)
        XCTAssertFalse(MenuBarVisibilityPolicy.loadRequireExternalDisplay(defaults: defaults))
    }

    func testExternalDisplayDetector_AnyNonBuiltinDisplayCountsAsExternal() {
        XCTAssertFalse(ExternalDisplayDetector.hasExternalDisplay(builtinStates: []))
        XCTAssertFalse(ExternalDisplayDetector.hasExternalDisplay(builtinStates: [true]))
        XCTAssertTrue(ExternalDisplayDetector.hasExternalDisplay(builtinStates: [true, false]))
        XCTAssertTrue(ExternalDisplayDetector.hasExternalDisplay(builtinStates: [false]))
    }

    // MARK: - Compact Mode Tests

    func testCompactMode_FormatsCorrectly() async throws {
        // Given: Compact mode settings
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .compact
        settings.changeFormat = .percentage

        // When: Format stock title
        let result = service.formatStockTitle(
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
        let result = service.formatStockTitle(
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

    func testDefaultDisplayModeUsesCurrentPriceAndPercentage() {
        // Given: Fresh menu bar display settings
        let settings = MenuBarDisplaySettings()

        // Then: The default explicitly shows current price and percentage change
        XCTAssertEqual(settings.displayMode, .priceAndPercentage)
        XCTAssertEqual(settings.effectiveTemplate, "{symbol} {price} {changePct}")
    }

    func testCurrentPriceModesAreAvailableInDisplayModePicker() {
        // Given: The modes rendered by the settings picker
        let modes = MenuBarDisplaySettings.DisplayMode.allCases

        // Then: Both explicit current-price choices are available with clear labels
        XCTAssertTrue(modes.contains(.priceAndPercentage))
        XCTAssertTrue(modes.contains(.priceAndShareChange))
        XCTAssertEqual(MenuBarDisplaySettings.DisplayMode.priceAndPercentage.description, "Current price + % change")
        XCTAssertEqual(
            MenuBarDisplaySettings.DisplayMode.priceAndShareChange.description,
            "Current price + per-share change"
        )
    }

    func testPriceAndPercentageModeShowsPriceAndPercentage() async throws {
        // Given: The explicit price and percentage display mode
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .priceAndPercentage

        // When: A positive stock title is formatted
        let result = service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.45,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: It includes the current price and percentage change
        XCTAssertEqual(result.string, "AAPL $175.23 +2.45%")
    }

    func testPriceAndShareChangeModeShowsPositivePerShareChange() async throws {
        // Given: The explicit price and per-share change display mode
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .priceAndShareChange

        // When: A positive stock title is formatted
        let result = service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.45,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: It includes the current price and signed per-share change
        XCTAssertEqual(result.string, "AAPL $175.23 +$4.29")
    }

    func testPriceAndShareChangeModePreservesNegativeSign() async throws {
        // Given: The explicit price and per-share change display mode
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .priceAndShareChange

        // When: A negative stock title is formatted
        let result = service.formatStockTitle(
            symbol: "TSLA",
            price: 250.00,
            change: -10.50,
            changePct: -4.03,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        // Then: The per-share change keeps its negative sign
        XCTAssertEqual(result.string, "TSLA $250.00 -$10.50")
    }

    func testExpandedMode_FormatsCorrectly() async throws {
        // Given: Expanded mode settings
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .percentage
        settings.decimalPlaces = 2

        // When: Format stock title
        let result = service.formatStockTitle(
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
        let result = service.formatStockTitle(
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
        settings.arrowStyle = .simple
        settings.arrowStyle = .simple

        // When: Format stock title (positive change)
        let result = service.formatStockTitle(
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

    func testMinimalModePrintsTheArrowOnce() async {
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .minimal
        settings.arrowStyle = .simple
        for before in [true, false] {
            settings.showArrowBeforeSymbol = before
            let result = service.formatStockTitle(
                symbol: "NVDA", price: 450, change: 10, changePct: 2.27,
                currency: "USD", settings: settings, useColorCoding: false
            )
            XCTAssertEqual(result.string, "NVDA \(settings.arrowStyle.upArrow())")
        }
    }

    /// The whole title, character for character, for the layouts people use.
    func testExactTitlesAcrossModesAndCurrencies() async {
        func title(
            _ mode: MenuBarDisplaySettings.DisplayMode,
            _ format: MenuBarDisplaySettings.ChangeFormat,
            price: Double = 450, change: Double = -10, pct: Double = -2.17,
            dayPL: Double = 0, currency: String = "USD"
        ) async -> String {
            var settings = MenuBarDisplaySettings()
            settings.displayMode = mode
            settings.changeFormat = format
            settings.arrowStyle = .none
            settings.decimalPlaces = 2
            return service.formatStockTitle(
                symbol: "NVDA", price: price, change: change, changePct: pct, dayPL: dayPL,
                currency: currency, settings: settings, useColorCoding: false
            ).string
        }

        let compactPercent = await title(.compact, .percentage)
        XCTAssertEqual(compactPercent, "NVDA -2.17%")
        let compactBoth = await title(.compact, .both)
        XCTAssertEqual(compactBoth, "NVDA -$10.00 (-2.17%)")
        let expandedPounds = await title(.expanded, .dollar, price: 12.5, change: 0.25, pct: 2.04, currency: "GBP")
        XCTAssertEqual(expandedPounds, "NVDA £12.50 +£0.25")
        let positionPL = await title(.expanded, .positionPLPct, dayPL: -250, currency: "USD")
        XCTAssertEqual(positionPL, "NVDA $450.00 -$250.00 (-2.17%)")
        let noPrice = await title(.priceAndPercentage, .percentage, price: .nan, change: .nan, pct: .nan)
        XCTAssertEqual(noPrice, "NVDA — —")
    }

    func testChangeTooSmallToShowIsNeutral() async {
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .compact
        settings.changeFormat = .percentage
        settings.arrowStyle = .simple
        settings.decimalPlaces = 2
        let result = service.formatStockTitle(
            symbol: "NVDA", price: 450, change: 0.001, changePct: 0.0004,
            currency: "USD", settings: settings, useColorCoding: true
        )
        XCTAssertEqual(result.string, "NVDA 0.00%")
        XCTAssertEqual(
            result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.labelColor
        )
    }

    func testMinimalMode_WithNegativeChange() async throws {
        // Given: Minimal mode with down arrow
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .minimal
        settings.arrowStyle = .simple
        settings.arrowStyle = .simple

        // When: Format stock title (negative change)
        let result = service.formatStockTitle(
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
        let result = service.formatStockTitle(
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
        let result = service.formatStockTitle(
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
        let result = service.formatStockTitle(
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
        let result = service.formatStockTitle(
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
        let result = service.formatStockTitle(
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
        let result = service.formatStockTitle(
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
        let result = service.formatStockTitle(
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

    func testColorCodingChangesWithoutWaitingForCachedPricesToExpire() async {
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .priceAndPercentage

        for change in [2.0, -2.0] {
            let plain = service.formatStockTitle(
                symbol: "AAPL", price: 100, change: change, changePct: change,
                currency: "USD", settings: settings, useColorCoding: false
            )
            let colored = service.formatStockTitle(
                symbol: "AAPL", price: 100, change: change, changePct: change,
                currency: "USD", settings: settings, useColorCoding: true
            )
            let plainAgain = service.formatStockTitle(
                symbol: "AAPL", price: 100, change: change, changePct: change,
                currency: "USD", settings: settings, useColorCoding: false
            )
            XCTAssertEqual(plain.string, colored.string)
            XCTAssertNil(plain.attribute(.foregroundColor, at: 0, effectiveRange: nil))
            let color = colored.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            XCTAssertEqual(color, change > 0 ? NSColor.systemGreen : NSColor.systemRed)
            XCTAssertNil(plainAgain.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        }
    }

    func testColorCoding_PositiveChange() async throws {
        // Given: Positive change with color coding
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.changeFormat = .percentage

        // When: Format with color coding enabled
        let result = service.formatStockTitle(
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
        result.enumerateAttribute(
            NSAttributedString.Key.foregroundColor,
            in: NSRange(location: 0, length: result.length)
        ) { value, range, stop in
            if let color = value as? NSColor {
                if color.isGreenishForTest {
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
        let result = service.formatStockTitle(
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
        result.enumerateAttribute(
            NSAttributedString.Key.foregroundColor,
            in: NSRange(location: 0, length: result.length)
        ) { value, range, stop in
            if let color = value as? NSColor {
                if color.isReddishForTest {
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
        let result1 = service.formatStockTitle(
            symbol: "AAPL",
            price: 175.23,
            change: 4.29,
            changePct: 2.51,
            currency: "USD",
            settings: settings,
            useColorCoding: false
        )

        let result2 = service.formatStockTitle(
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

        let result1 = service.formatStockTitle(
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

        let result2 = service.formatStockTitle(
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
        settings.arrowStyle = .simple
        settings.arrowStyle = .simple

        // When: Format with positive change
        let result = service.formatStockTitle(
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

    func testZeroChangeIsNeutralWithoutArrowOrGreen() async throws {
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .compact
        settings.arrowStyle = .simple

        let result = service.formatStockTitle(
            symbol: "AAPL", price: 175.23, change: 0, changePct: 0,
            currency: "USD", settings: settings, useColorCoding: true)

        XCTAssertFalse(result.string.contains("▲"), "zero change must not show an up arrow: \(result.string)")
        XCTAssertFalse(result.string.contains("▼"))
        XCTAssertFalse(result.string.contains("+0"), "zero change carries no sign: \(result.string)")
        var sawGreenOrRed = false
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            if let color = value as? NSColor, color.isGreenishForTest || color.isReddishForTest {
                sawGreenOrRed = true
            }
        }
        XCTAssertFalse(sawGreenOrRed, "zero change is neither gain nor loss")
    }

    func testMissingPriceShowsDashNotZero() async throws {
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded

        for missing in [Double.nan, 0, -1] {
            let result = service.formatStockTitle(
                symbol: "AAPL", price: missing, change: .nan, changePct: .nan,
                currency: "USD", settings: settings, useColorCoding: false)
            XCTAssertTrue(result.string.contains("—"), "price \(missing) must render as a dash: \(result.string)")
            XCTAssertFalse(result.string.contains("0.00"), "missing price must not render as 0.00: \(result.string)")
        }
    }

    // MARK: - Currency Symbol Tests

    func testCurrencySymbol_USD() async throws {
        // Given: USD currency
        var settings = MenuBarDisplaySettings()
        settings.displayMode = .expanded
        settings.showCurrency = true

        // When: Format stock title
        let result = service.formatStockTitle(
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
        let result = service.formatStockTitle(
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

final class MenuPopoverUnitsFormattingTests: XCTestCase {
    func testUnitsDisplayPreservesFractionalShares() {
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(MenuPopoverFormatter.units(80.89145668, locale: locale), "80.89145668")
        XCTAssertEqual(MenuPopoverFormatter.units(1_250, locale: locale), "1,250")
        XCTAssertEqual(MenuPopoverFormatter.editableUnits(1_250.5, locale: locale), "1250.5")
    }

    func testParseUnitsAcceptsLocaleDecimalAndRejectsInvalidInput() throws {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(try XCTUnwrap(MenuPopoverFormatter.parseUnits("10,5", locale: german)), 10.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(MenuPopoverFormatter.parseUnits(" 10.25 ", locale: Locale(identifier: "en_US"))), 10.25, accuracy: 1e-9)
        XCTAssertNil(MenuPopoverFormatter.parseUnits("", locale: german))
        XCTAssertNil(MenuPopoverFormatter.parseUnits("abc", locale: german))
        XCTAssertNil(MenuPopoverFormatter.parseUnits("0", locale: german))
        XCTAssertNil(MenuPopoverFormatter.parseUnits("-3", locale: german))
    }
}

final class PortfolioMenuBarTitleFormatterTests: XCTestCase {
    private let locale = Locale(identifier: "en_GB")

    func testDayGainFormatIsHonoured() {
        var settings = PortfolioMenuBarDisplaySettings(isEnabled: true, currencyCode: "GBP", dayGainFormat: .both, decimalPlaces: 2)
        XCTAssertEqual(
            PortfolioMenuBarTitleFormatter.title(totalValue: 10_234.56, dayGain: -123.45, dayGainPercent: -1.21, settings: settings, locale: locale),
            "£10,234.56 -£123.45 (-1.21%)"
        )

        settings.dayGainFormat = .currency
        XCTAssertEqual(
            PortfolioMenuBarTitleFormatter.title(totalValue: 10_234.56, dayGain: 123.45, dayGainPercent: 1.21, settings: settings, locale: locale),
            "£10,234.56 +£123.45"
        )

        settings.dayGainFormat = .percentage
        settings.decimalPlaces = 0
        XCTAssertEqual(
            PortfolioMenuBarTitleFormatter.title(totalValue: 10_234.56, dayGain: 123.45, dayGainPercent: 1.21, settings: settings, locale: locale),
            "£10,235 +1.21%"
        )
    }

    func testChangeThatPrintsAsZeroCarriesNoSign() {
        let settings = PortfolioMenuBarDisplaySettings(isEnabled: true, currencyCode: "GBP", dayGainFormat: .both, decimalPlaces: 2)
        XCTAssertEqual(
            PortfolioMenuBarTitleFormatter.title(totalValue: 100, dayGain: 0.004, dayGainPercent: 0.004, settings: settings, locale: locale),
            "£100.00 £0.00 (0.00%)"
        )
        XCTAssertEqual(
            PortfolioMenuBarTitleFormatter.title(totalValue: 100, dayGain: -0.004, dayGainPercent: -0.004, settings: settings, locale: locale),
            "£100.00 £0.00 (0.00%)"
        )
    }

    func testRoundedForDisplayTreatsTinyAndMissingValuesAsZero() {
        XCTAssertEqual(MenuBarFormattingService.roundedForDisplay(-0.004, decimalPlaces: 2), 0)
        XCTAssertEqual(MenuBarFormattingService.roundedForDisplay(-0.004, decimalPlaces: 2).sign, .plus)
        XCTAssertEqual(MenuBarFormattingService.roundedForDisplay(-0.006, decimalPlaces: 2), -0.01)
        XCTAssertEqual(MenuBarFormattingService.roundedForDisplay(.nan, decimalPlaces: 2), 0)
    }

    func testSettingsPreviewUsesTheSameFormatter() {
        let settings = PortfolioMenuBarDisplaySettings(isEnabled: true, currencyCode: "USD", dayGainFormat: .both, decimalPlaces: 2)
        XCTAssertEqual(settings.samplePreview(locale: Locale(identifier: "en_US")), "$10,234.56 +$123.45 (+1.21%)")
    }

    func testExchangeDisplayNames() {
        XCTAssertEqual(SymbolMetadata.exchangeDisplayName(for: "IAG.L"), "London Stock Exchange")
        XCTAssertEqual(SymbolMetadata.exchangeDisplayName(for: "AAPL"), "US Market")
        XCTAssertEqual(SymbolMetadata.exchangeDisplayName(for: "^GSPC"), "Index")
        XCTAssertEqual(SymbolMetadata.exchangeDisplayName(for: "SHOP.TO"), "Toronto Stock Exchange")
        XCTAssertEqual(SymbolMetadata.exchangeDisplayName(for: "BTC-USD"), "Crypto")
    }
}

@MainActor
final class StatusButtonClickPolicyTests: XCTestCase {
    private func window(at origin: NSPoint) -> NSWindow {
        NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 60, height: 24)),
                 styleMask: [.borderless], backing: .buffered, defer: true)
    }

    func testEventDeliveredToTheButtonWindowIsIgnored() {
        let button = window(at: NSPoint(x: 100, y: 100))
        let other = window(at: NSPoint(x: 400, y: 400))

        XCTAssertTrue(StatusButtonClickPolicy.isStatusButtonEvent(
            eventWindow: button, buttonWindow: button, mouseLocation: .zero))
        XCTAssertFalse(StatusButtonClickPolicy.isStatusButtonEvent(
            eventWindow: other, buttonWindow: button, mouseLocation: NSPoint(x: 110, y: 110)))
    }

    func testGlobalEventWithoutWindowUsesThePointerLocation() {
        let button = window(at: NSPoint(x: 100, y: 100))

        XCTAssertTrue(StatusButtonClickPolicy.isStatusButtonEvent(
            eventWindow: nil, buttonWindow: button, mouseLocation: NSPoint(x: 110, y: 110)))
        XCTAssertFalse(StatusButtonClickPolicy.isStatusButtonEvent(
            eventWindow: nil, buttonWindow: button, mouseLocation: NSPoint(x: 500, y: 500)))
        XCTAssertFalse(StatusButtonClickPolicy.isStatusButtonEvent(
            eventWindow: nil, buttonWindow: nil, mouseLocation: NSPoint(x: 110, y: 110)))
    }
}

final class BackupPreviewFormatTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testUnitsKeepFractionalSharesInsteadOfRoundingToTwoDecimals() {
        XCTAssertEqual(BackupPreviewFormat.units(0.123456, locale: locale), "0.123456")
        XCTAssertEqual(BackupPreviewFormat.units(1_250, locale: locale), "1,250")
        XCTAssertEqual(BackupPreviewFormat.units(.nan, locale: locale), "—")
    }

    func testCostKeepsSubPennyPrecisionAndMissingIsADash() {
        XCTAssertEqual(BackupPreviewFormat.cost(12.5, currency: "GBP", locale: locale), "GBP 12.50")
        XCTAssertEqual(BackupPreviewFormat.cost(0.0123, currency: "USD", locale: locale), "USD 0.0123")
        XCTAssertEqual(BackupPreviewFormat.cost(10, currency: nil, locale: locale), "10.00")
        XCTAssertEqual(BackupPreviewFormat.cost(.nan, currency: "USD", locale: locale), "—")
    }
}

@MainActor
final class HoldingsAndStatusViewHelperTests: XCTestCase {
    func testMoveSkipsHiddenRowsAndStopsAtTheEdges() {
        // Rows 1 and 3 are hidden (a benchmark and a search filter), so 0, 2 and 4 are visible.
        let visible = [0, 2, 4]

        XCTAssertEqual(HoldingsEditing.moveDestination(from: 2, by: -1, visibleIndices: visible), 0)
        XCTAssertEqual(HoldingsEditing.moveDestination(from: 2, by: 1, visibleIndices: visible), 4)
        XCTAssertNil(HoldingsEditing.moveDestination(from: 0, by: -1, visibleIndices: visible), "first visible row cannot move up")
        XCTAssertNil(HoldingsEditing.moveDestination(from: 4, by: 1, visibleIndices: visible), "last visible row cannot move down")
        XCTAssertNil(HoldingsEditing.moveDestination(from: 1, by: 1, visibleIndices: visible), "a hidden row is not movable")
        XCTAssertNil(HoldingsEditing.moveDestination(from: 2, by: 0, visibleIndices: visible))
    }

    func testCurrencyOptionsCoverEverySupportedCurrencyAndKeepLegacyCodes() {
        let options = HoldingsEditing.currencyOptions(current: nil)

        XCTAssertTrue(options.contains("GBX"))
        for currency in DataModel.supportedCurrencies {
            XCTAssertTrue(options.contains(currency), "\(currency) must be selectable")
        }
        XCTAssertTrue(options.contains("CAD") && options.contains("AUD"))
        XCTAssertEqual(Set(options).count, options.count, "no duplicates")
        XCTAssertTrue(HoldingsEditing.currencyOptions(current: "CHF").contains("CHF"))
        XCTAssertEqual(HoldingsEditing.currencyOptions(current: "USD"), options)
    }

    func testOldestPriceUpdateIsNotHiddenByFresherQuotes() {
        let result = StockbarRelativeTime.oldest([1_700_000_500, 1_700_000_000, 1_700_009_000])
        XCTAssertEqual(result.date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(result.missingCount, 0)

        let withMissing = StockbarRelativeTime.oldest([1_700_000_500, nil, 0])
        XCTAssertEqual(withMissing.date, Date(timeIntervalSince1970: 1_700_000_500))
        XCTAssertEqual(withMissing.missingCount, 2, "a position that never updated is counted, not skipped")

        let none = StockbarRelativeTime.oldest([])
        XCTAssertNil(none.date)
        XCTAssertEqual(none.missingCount, 0)
    }

    func testStatusItemDirectionWordsAndVerificationStatusText() {
        XCTAssertEqual(StatusItemAccessibility.direction(of: 1.5), "up")
        XCTAssertEqual(StatusItemAccessibility.direction(of: -1.5), "down")
        XCTAssertEqual(StatusItemAccessibility.direction(of: 0), "unchanged")
        XCTAssertEqual(StatusItemAccessibility.direction(of: .nan), "change unavailable")

        XCTAssertEqual(DataSourcesSettingsView.statusDescription(.success), "Verified")
        XCTAssertEqual(DataSourcesSettingsView.statusDescription(.failure), "Verification failed")
        XCTAssertEqual(DataSourcesSettingsView.statusDescription(.none), "Not verified")
        XCTAssertEqual(DataSourcesSettingsView.statusDescription(.verifying), "Verifying")
    }
}

/// Main-window and settings fixes from the audit.
@MainActor
final class MainWindowAuditFixTests: XCTestCase {
    func testZeroAmountsCarryNoSignAndNegativesPutTheSignFirst() {
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(0, currency: "GBP"), "£0.00")
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(-0.001, currency: "GBP"), "£0.00")
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(0.004, currency: "USD"), "$0.00")
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(5, currency: "GBP"), "+£5.00")
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(-5, currency: "GBP"), "-£5.00")
        XCTAssertEqual(HoldingsCurrencyFormatter.amount(-5, currency: "GBP"), "-£5.00")
        XCTAssertEqual(HoldingsCurrencyFormatter.amount(-0.001, currency: "GBP"), "£0.00")
        XCTAssertEqual(HoldingsCurrencyFormatter.compactAmount(-0.001, currency: "GBP", includeSign: true), "£0.00")
    }

    func testAmountThatDisplaysAsZeroIsNotColouredAsAGainOrLoss() {
        XCTAssertEqual(HoldingsCurrencyFormatter.displayedSign(of: -0.001, currency: "GBP"), 0)
        XCTAssertEqual(HoldingsCurrencyFormatter.displayedSign(of: 0.004, currency: "GBP"), 0)
        XCTAssertLessThan(HoldingsCurrencyFormatter.displayedSign(of: -0.02, currency: "GBP"), 0)
        XCTAssertGreaterThan(HoldingsCurrencyFormatter.displayedSign(of: 12, currency: "GBP"), 0)
        XCTAssertEqual(HoldingsCurrencyFormatter.displayedSign(of: .nan, currency: "GBP"), 0)
    }

    func testAlertMoneyMatchesTheHoldingsTableAndNeverGuessesACurrency() {
        let alert = PriceAlert(symbol: "AAPL", condition: .above, threshold: 150)
        XCTAssertEqual(alert.formattedThreshold(currency: "GBP"), "£150.00")
        XCTAssertEqual(alert.formattedThreshold(currency: "USD"), "$150.00")
        XCTAssertEqual(alert.formattedThreshold(currency: ""), "150.00")
        let percent = PriceAlert(symbol: "AAPL", condition: .percentChange, threshold: 5)
        XCTAssertEqual(percent.formattedThreshold(currency: "GBP"), "5.0%")
    }

    func testWindowAlreadyOnScreenIsLeftExactlyWhereItIs() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1080)
        let nearEdge = NSRect(x: 4, y: 6, width: 1200, height: 800)
        XCTAssertEqual(StockbarMainWindowController.frame(nearEdge, fittedTo: screen), nearEdge)
    }

    func testWindowOffScreenIsMovedBackAndOnlyShrunkWhenTooBig() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offRight = NSRect(x: 1300, y: 100, width: 1100, height: 700)
        let moved = StockbarMainWindowController.frame(offRight, fittedTo: screen)
        XCTAssertEqual(moved.size, offRight.size)
        XCTAssertTrue(screen.contains(moved))

        let tooBig = NSRect(x: -200, y: -200, width: 2000, height: 1400)
        let fitted = StockbarMainWindowController.frame(tooBig, fittedTo: screen)
        XCTAssertEqual(fitted, screen)
    }

    func testTemplateTokenHelpListsExactlyTheAcceptedPlaceholders() {
        XCTAssertEqual(Set(MenuBarDisplaySettings.orderedPlaceholders), MenuBarDisplaySettings.validPlaceholders)
        XCTAssertEqual(MenuBarDisplaySettings.orderedPlaceholders.count, MenuBarDisplaySettings.validPlaceholders.count)
    }

    func testBackingUpAnEmptyPortfolioIsNotReportedAsAFailure() async {
        let outcome = await BackupService.shared.performManualBackupReportingOutcome(trades: [])
        XCTAssertEqual(outcome, .nothingToBackUp)
        XCTAssertFalse(outcome.userMessage.localizedCaseInsensitiveContains("failed"))
        XCTAssertTrue(BackupOutcome.failed.userMessage.localizedCaseInsensitiveContains("failed"))
    }
}
