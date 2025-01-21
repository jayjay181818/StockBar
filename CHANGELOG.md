# Changelog

## [1.3.0] - 2024-01-21

### Changed
- Refactored StockStatusBar to improve code organization and reduce dependencies
- Removed forced unwrapping and try statements for better stability
- Updated PreferenceView parameter naming for consistency
- Improved memory management with proper weak self references

### Added
- New TradingData struct for better type safety
- Proper error handling in PreferenceViewController
- Better currency formatting in menu items
- More modular code structure with separate update methods

### Fixed
- Fixed force unwrapping issues in YahooFinanceDecoder
- Corrected parameter naming inconsistencies
- Fixed memory leaks in status bar controllers
- Resolved build errors related to Logger and StockData dependencies

### Technical Improvements
- Split large functions into smaller, more focused methods
- Added proper MARK comments for better code navigation
- Improved type safety throughout the application
- Better handling of optional values
