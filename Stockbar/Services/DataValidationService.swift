//
//  DataValidationService.swift
//  Stockbar
//
//  Comprehensive data validation and sanitization service
//  Validates user inputs, stock data, and prevents invalid states
//

import Foundation

// MARK: - Validation Error Types
enum ValidationError: Error, CustomStringConvertible {
    case invalidSymbol(String)
    case invalidPrice(Double)
    case invalidUnits(Double)
    case invalidCost(Double)
    case invalidCurrency(String)
    case invalidPercentage(Double)
    case emptyValue(String)
    case outOfRange(String, min: Double, max: Double)
    case invalidFormat(String)

    var description: String {
        switch self {
        case .invalidSymbol(let symbol):
            return "Invalid symbol: '\(symbol)'. Symbols must be 1-10 characters, alphanumeric with optional dots/hyphens."
        case .invalidPrice(let price):
            return "Invalid price: \(price). Price must be positive and finite."
        case .invalidUnits(let units):
            return "Invalid units: \(units). Units must be positive."
        case .invalidCost(let cost):
            return "Invalid cost: \(cost). Cost must be positive."
        case .invalidCurrency(let currency):
            return "Invalid currency: '\(currency)'. Must be a valid 3-letter currency code."
        case .invalidPercentage(let value):
            return "Invalid percentage: \(value). Must be between 0 and 100."
        case .emptyValue(let field):
            return "Required field '\(field)' is empty."
        case .outOfRange(let field, let min, let max):
            return "Value for '\(field)' must be between \(min) and \(max)."
        case .invalidFormat(let field):
            return "Invalid format for '\(field)'."
        }
    }
}

// MARK: - Validation Result
struct ValidationResult {
    let isValid: Bool
    let errors: [ValidationError]
    let sanitizedValue: Any?

    static func success(_ value: Any? = nil) -> ValidationResult {
        ValidationResult(isValid: true, errors: [], sanitizedValue: value)
    }

    static func failure(_ errors: [ValidationError]) -> ValidationResult {
        ValidationResult(isValid: false, errors: errors, sanitizedValue: nil)
    }
}

// MARK: - Data Validation Service
class DataValidationService {
    static let shared = DataValidationService()

    private let supportedCurrencies = Set(["USD", "GBP", "EUR", "JPY", "CAD", "AUD"])
    private let maxSymbolLength = 10
    private let minSymbolLength = 1

    private init() {}

    // MARK: - Symbol Validation

    /// Validates a stock symbol
    func validateSymbol(_ symbol: String) -> ValidationResult {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // Check if empty
        guard !trimmed.isEmpty else {
            return .failure([.emptyValue("symbol")])
        }

        // Check length
        guard trimmed.count >= minSymbolLength && trimmed.count <= maxSymbolLength else {
            return .failure([.invalidSymbol(symbol)])
        }

        // Check format: alphanumeric with optional dots and hyphens
        let symbolPattern = "^[A-Z0-9.-]+$"
        let symbolRegex = try? NSRegularExpression(pattern: symbolPattern)
        let range = NSRange(trimmed.startIndex..., in: trimmed)

        guard symbolRegex?.firstMatch(in: trimmed, range: range) != nil else {
            return .failure([.invalidSymbol(symbol)])
        }

        return .success(trimmed)
    }

    // MARK: - Price Validation

    /// Validates a stock price
    func validatePrice(_ price: Double) -> ValidationResult {
        guard price.isFinite else {
            return .failure([.invalidPrice(price)])
        }

        guard price > 0 else {
            return .failure([.invalidPrice(price)])
        }

        // Check for reasonable upper bound (e.g., $1 million per share)
        guard price <= 1_000_000 else {
            return .failure([.outOfRange("price", min: 0, max: 1_000_000)])
        }

        return .success(price)
    }

    /// Validates and sanitizes price data, returning cleaned value or nil
    func sanitizePrice(_ price: Double) -> Double? {
        guard price.isFinite && price > 0 && price <= 1_000_000 else {
            return nil
        }
        return price
    }

    // MARK: - Position Validation

    /// Validates trade units (shares/quantity)
    func validateUnits(_ units: Double) -> ValidationResult {
        guard units.isFinite else {
            return .failure([.invalidUnits(units)])
        }

        guard units > 0 else {
            return .failure([.invalidUnits(units)])
        }

        // Check for reasonable upper bound (e.g., 1 billion shares)
        guard units <= 1_000_000_000 else {
            return .failure([.outOfRange("units", min: 0, max: 1_000_000_000)])
        }

        return .success(units)
    }

    /// Validates average cost per unit
    func validateCost(_ cost: Double) -> ValidationResult {
        guard cost.isFinite else {
            return .failure([.invalidCost(cost)])
        }

        guard cost > 0 else {
            return .failure([.invalidCost(cost)])
        }

        // Check for reasonable upper bound
        guard cost <= 1_000_000 else {
            return .failure([.outOfRange("cost", min: 0, max: 1_000_000)])
        }

        return .success(cost)
    }

    // MARK: - Currency Validation

    /// Validates currency code
    func validateCurrency(_ currency: String) -> ValidationResult {
        let trimmed = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard !trimmed.isEmpty else {
            return .failure([.emptyValue("currency")])
        }

        guard trimmed.count == 3 else {
            return .failure([.invalidCurrency(currency)])
        }

        guard supportedCurrencies.contains(trimmed) else {
            return .failure([.invalidCurrency(currency)])
        }

        return .success(trimmed)
    }

    // MARK: - Percentage Validation

    /// Validates percentage values (0-100)
    func validatePercentage(_ percentage: Double) -> ValidationResult {
        guard percentage.isFinite else {
            return .failure([.invalidPercentage(percentage)])
        }

        guard percentage >= 0 && percentage <= 100 else {
            return .failure([.invalidPercentage(percentage)])
        }

        return .success(percentage)
    }

    // MARK: - Trade Validation

    /// Validates complete trade data
    func validateTrade(symbol: String, units: String, cost: String, currency: String) -> ValidationResult {
        var errors: [ValidationError] = []

        // Validate symbol
        let symbolResult = validateSymbol(symbol)
        if !symbolResult.isValid {
            errors.append(contentsOf: symbolResult.errors)
        }

        // Validate units
        guard let unitsValue = Double(units) else {
            errors.append(.invalidFormat("units"))
            return .failure(errors)
        }
        let unitsResult = validateUnits(unitsValue)
        if !unitsResult.isValid {
            errors.append(contentsOf: unitsResult.errors)
        }

        // Validate cost
        guard let costValue = Double(cost) else {
            errors.append(.invalidFormat("cost"))
            return .failure(errors)
        }
        let costResult = validateCost(costValue)
        if !costResult.isValid {
            errors.append(contentsOf: costResult.errors)
        }

        // Validate currency
        let currencyResult = validateCurrency(currency)
        if !currencyResult.isValid {
            errors.append(contentsOf: currencyResult.errors)
        }

        if errors.isEmpty {
            return .success((
                symbol: symbolResult.sanitizedValue as! String,
                units: unitsValue,
                cost: costValue,
                currency: currencyResult.sanitizedValue as! String
            ))
        } else {
            return .failure(errors)
        }
    }

    // MARK: - String to Number Conversion with Validation

    /// Safely converts string to Double with validation
    func parseDouble(_ string: String, fieldName: String) -> ValidationResult {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .failure([.emptyValue(fieldName)])
        }

        guard let value = Double(trimmed) else {
            return .failure([.invalidFormat(fieldName)])
        }

        guard value.isFinite else {
            return .failure([.invalidFormat(fieldName)])
        }

        return .success(value)
    }

    // MARK: - Data Sanitization

    /// Sanitizes stock fetch result data
    func sanitizeStockData(price: Double, previousClose: Double) -> (price: Double?, previousClose: Double?) {
        let sanitizedPrice = sanitizePrice(price)
        let sanitizedPrevClose = sanitizePrice(previousClose)
        return (sanitizedPrice, sanitizedPrevClose)
    }

    /// Validates and sanitizes interval values (e.g., refresh intervals)
    func validateInterval(_ interval: TimeInterval, min: TimeInterval, max: TimeInterval) -> ValidationResult {
        guard interval.isFinite else {
            return .failure([.invalidFormat("interval")])
        }

        guard interval >= min && interval <= max else {
            return .failure([.outOfRange("interval", min: min, max: max)])
        }

        return .success(interval)
    }

    // MARK: - Batch Validation

    /// Validates multiple trades at once
    func validateTrades(_ trades: [(symbol: String, units: String, cost: String, currency: String)]) -> [ValidationResult] {
        return trades.map { trade in
            validateTrade(symbol: trade.symbol, units: trade.units, cost: trade.cost, currency: trade.currency)
        }
    }

    // MARK: - Error Formatting

    /// Formats validation errors into user-friendly message
    func formatErrors(_ errors: [ValidationError]) -> String {
        if errors.isEmpty {
            return "No errors"
        }

        if errors.count == 1 {
            return errors[0].description
        }

        return errors.enumerated().map { index, error in
            "\(index + 1). \(error.description)"
        }.joined(separator: "\n")
    }
}
