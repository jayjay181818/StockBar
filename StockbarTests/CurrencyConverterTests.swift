import XCTest
@testable import Stockbar

class CurrencyConverterTests: XCTestCase {

    var converter: CurrencyConverter!

    override func setUp() {
        super.setUp()
        converter = CurrencyConverter.shared

        // Set up mock exchange rates for testing
        converter.exchangeRates = [
            "USD": 1.0,
            "GBP": 0.79,
            "EUR": 0.92,
            "JPY": 149.50,
            "CAD": 1.36,
            "AUD": 1.53
        ]
    }

    override func tearDown() {
        converter = nil
        super.tearDown()
    }

    // MARK: - Basic Currency Conversion Tests

    func testUSDToGBPConversion() {
        let result = converter.convert(amount: 100, from: "USD", to: "GBP")
        XCTAssertEqual(result, 79.0, accuracy: 0.01, "100 USD should convert to approximately 79 GBP")
    }

    func testGBPToUSDConversion() {
        let result = converter.convert(amount: 79, from: "GBP", to: "USD")
        XCTAssertEqual(result, 100.0, accuracy: 0.01, "79 GBP should convert to approximately 100 USD")
    }

    func testSameCurrencyConversion() {
        let result = converter.convert(amount: 100, from: "USD", to: "USD")
        XCTAssertEqual(result, 100.0, "Converting to same currency should return same amount")
    }

    func testMultipleCurrencyPairs() {
        // USD -> EUR
        let usdToEur = converter.convert(amount: 100, from: "USD", to: "EUR")
        XCTAssertEqual(usdToEur, 92.0, accuracy: 0.01)

        // EUR -> JPY
        let eurToJpy = converter.convert(amount: 100, from: "EUR", to: "JPY")
        XCTAssertGreaterThan(eurToJpy, 0)

        // JPY -> CAD
        let jpyToCad = converter.convert(amount: 1000, from: "JPY", to: "CAD")
        XCTAssertGreaterThan(jpyToCad, 0)
    }

    // MARK: - GBX to GBP Conversion Tests (Critical for UK stocks)

    func testGBXToGBPConversion() {
        // GBX is pence, GBP is pounds (1 GBP = 100 GBX)
        let result = converter.convert(amount: 150, from: "GBX", to: "GBP")
        XCTAssertEqual(result, 1.5, accuracy: 0.001, "150 pence should equal 1.5 pounds")
    }

    func testGBPToGBXConversion() {
        let result = converter.convert(amount: 1.5, from: "GBP", to: "GBX")
        XCTAssertEqual(result, 150.0, accuracy: 0.01, "1.5 pounds should equal 150 pence")
    }

    func testGBXToUSDConversion() {
        // GBX -> GBP -> USD
        let result = converter.convert(amount: 100, from: "GBX", to: "USD")
        // 100 GBX = 1 GBP, 1 GBP ≈ 1.266 USD (1 / 0.79)
        XCTAssertEqual(result, 1.266, accuracy: 0.01)
    }

    func testUSDToGBXConversion() {
        // USD -> GBP -> GBX
        let result = converter.convert(amount: 1.266, from: "USD", to: "GBX")
        // 1.266 USD ≈ 1 GBP = 100 GBX
        XCTAssertEqual(result, 100.0, accuracy: 1.0)
    }

    // MARK: - Edge Case Tests

    func testZeroAmountConversion() {
        let result = converter.convert(amount: 0, from: "USD", to: "GBP")
        XCTAssertEqual(result, 0.0, "Converting zero should return zero")
    }

    func testNegativeAmountConversion() {
        let result = converter.convert(amount: -100, from: "USD", to: "GBP")
        XCTAssertEqual(result, -79.0, accuracy: 0.01, "Negative amounts should convert correctly")
    }

    func testNaNConversion() {
        let result = converter.convert(amount: Double.nan, from: "USD", to: "GBP")
        XCTAssertTrue(result.isNaN, "Converting NaN should return NaN")
    }

    func testInfinityConversion() {
        let result = converter.convert(amount: Double.infinity, from: "USD", to: "GBP")
        XCTAssertTrue(result.isInfinite, "Converting infinity should return infinity")
    }

    func testVeryLargeAmountConversion() {
        let result = converter.convert(amount: 1_000_000_000, from: "USD", to: "GBP")
        XCTAssertGreaterThan(result, 0)
        XCTAssertTrue(result.isFinite)
    }

    func testVerySmallAmountConversion() {
        let result = converter.convert(amount: 0.0001, from: "USD", to: "GBP")
        XCTAssertGreaterThan(result, 0)
        XCTAssertLessThan(result, 1)
    }

    // MARK: - Invalid Currency Tests

    func testInvalidSourceCurrency() {
        let result = converter.convert(amount: 100, from: "XXX", to: "USD")
        XCTAssertEqual(result, 100.0, "Unknown source currency should return original amount")
    }

    func testInvalidTargetCurrency() {
        let result = converter.convert(amount: 100, from: "USD", to: "XXX")
        XCTAssertEqual(result, 100.0, "Unknown target currency should return original amount")
    }

    func testEmptySourceCurrency() {
        let result = converter.convert(amount: 100, from: "", to: "USD")
        XCTAssertEqual(result, 100.0)
    }

    func testEmptyTargetCurrency() {
        let result = converter.convert(amount: 100, from: "USD", to: "")
        XCTAssertEqual(result, 100.0)
    }

    // MARK: - Rate Availability Tests

    func testAllSupportedCurrenciesHaveRates() {
        let supportedCurrencies = ["USD", "GBP", "EUR", "JPY", "CAD", "AUD"]

        for currency in supportedCurrencies {
            XCTAssertNotNil(converter.exchangeRates[currency], "\(currency) should have an exchange rate")
            XCTAssertGreaterThan(converter.exchangeRates[currency] ?? 0, 0, "\(currency) rate should be positive")
        }
    }

    func testRoundTripConversion() {
        // Convert USD -> GBP -> USD should return original amount (within rounding)
        let original = 100.0
        let toGBP = converter.convert(amount: original, from: "USD", to: "GBP")
        let backToUSD = converter.convert(amount: toGBP, from: "GBP", to: "USD")

        XCTAssertEqual(backToUSD, original, accuracy: 0.01, "Round-trip conversion should preserve value")
    }

    func testGBXRoundTripConversion() {
        // Convert GBX -> USD -> GBX should return original amount (within rounding)
        let original = 350.0 // 350 pence
        let toUSD = converter.convert(amount: original, from: "GBX", to: "USD")
        let backToGBX = converter.convert(amount: toUSD, from: "USD", to: "GBX")

        XCTAssertEqual(backToGBX, original, accuracy: 1.0, "GBX round-trip conversion should preserve value")
    }
}
