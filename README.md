# StockBar

A macOS menu bar application for tracking stock prices and portfolio performance.

## Features

- Real-time stock price monitoring
- Portfolio tracking with gains/losses
- Multi-currency support
- Customizable refresh intervals
- Clean menu bar interface

## Development Setup

### Prerequisites

- Xcode 13.0 or later
- macOS 11.0 or later
- SwiftLint (optional but recommended)

### Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/StockBar.git
cd StockBar
```

2. Install SwiftLint (optional):
```bash
brew install swiftlint
```

3. Open the project in Xcode:
```bash
open StockBar.xcodeproj
```

### Project Structure

```
StockBar/
├── StockBar/
│   ├── App/
│   │   └── AppDelegate.swift
│   ├── Data/
│   │   ├── DataModel.swift
│   │   ├── Trade.swift
│   │   └── YahooFinanceDecoder.swift
│   ├── Networking/
│   │   └── NetworkService.swift
│   ├── UI/
│   │   ├── StockStatusBar.swift
│   │   ├── PreferenceView.swift
│   │   └── SymbolMenu.swift
│   └── Utilities/
│       ├── Logger.swift
│       └── CurrencyConverter.swift
├── StockBarTests/
│   ├── DataModelTests.swift
│   └── NetworkServiceTests.swift
└── StockBarUITests/
    └── StockBarUITests.swift
```

### Testing

The project includes three types of tests:

1. Unit Tests: Testing individual components
```bash
xcodebuild test -scheme StockBar -only-testing:StockBarTests
```

2. UI Tests: Testing user interface interactions
```bash
xcodebuild test -scheme StockBar -only-testing:StockBarUITests
```

3. Integration Tests: Testing component interactions
```bash
xcodebuild test -scheme StockBar
```

### Code Style

This project uses SwiftLint to enforce consistent code style. The configuration can be found in `.swiftlint.yml`.

### Logging

The application uses a custom logging system that writes to both console (in debug) and file. Logs can be found at:
```
~/Library/Containers/com.yourdomain.StockBar/Data/Documents/stockbar.log
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.