# Changelog

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