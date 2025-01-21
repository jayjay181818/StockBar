# Changelog

## [0.2.0] - 2025-01-21

### Added
- Real-time currency conversion using exchangerate-api.com
- Support for all major currency pairs (USD, GBP, EUR, JPY, CAD, AUD)
- Automatic hourly exchange rate updates
- Manual refresh option for exchange rates

### Changed
- Simplified currency conversion architecture
- Improved error handling and fallbacks
- Enhanced state management in PreferenceView
- Better separation of concerns between components

### Technical Details
- Implemented CurrencyConverter as ObservableObject
- Added ExchangeRateResponse model for API integration
- Updated DataModel to handle currency conversion internally
- Improved error handling with proper fallbacks
- Enhanced logging throughout conversion process

### Developer Notes
The currency conversion system has been completely redesigned to:
- Use exchangerate-api.com for reliable real-time rates
- Handle currency conversion through a clean, focused API
- Provide proper error handling and fallbacks
- Maintain clean separation between UI and business logic

## [1.1.0] - 2025-01-17

### Added
- Support for proper GBX/GBp to GBP currency conversion for London Stock Exchange stocks
- Visual indicator showing when currency conversion occurs (→GBP)
- Comprehensive logging throughout the currency conversion process for debugging

### Changed
- Centralized currency conversion logic in Trade.swift
- Improved handling of both GBX and GBp currencies
- Enhanced price display accuracy for UK stocks

### Technical Details
- Implemented unified currency conversion in `convertPrice` function
- Added currency conversion logging for debugging purposes
- Updated YahooFinanceDecoder to preserve original currency information
- Modified StockStatusBar to use centralized currency conversion
- Improved price calculations to maintain precision during conversion

### Developer Notes
The currency conversion system now properly handles both GBX (pence sterling) and GBp (penny sterling) for London Stock Exchange stocks. All conversions are performed through a centralized `convertPrice` function, which:
- Converts GBX/GBp to GBP by dividing by 100
- Maintains the original currency information until final display
- Provides detailed logging for troubleshooting