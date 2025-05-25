# Technical Context

This file describes the technologies used, development setup, and technical constraints of the project.

**Technologies used:**
- **Swift**: Primary language for macOS application development
- **AppKit**: Native macOS UI framework for menu bar integration
- **Combine**: Reactive programming framework for data binding and UI updates
- **Foundation**: Core framework for data handling and persistence
- **Python 3**: Backend script for stock data fetching
- **yfinance**: Python library for Yahoo Finance API access
- **UserDefaults**: Persistent storage for user preferences and stock data
- **JSON Encoding/Decoding**: Data serialization for persistent storage

**Development setup:**
- **Xcode**: Primary IDE for Swift development and project management
- **Python Environment**: Requires Python 3 with yfinance library installed
- **macOS Target**: Native macOS application with menu bar integration
- **Project Structure**: Standard Xcode project with Swift Package Manager dependencies

**Technical constraints:**
- **API Rate Limiting**: Yahoo Finance API has rate limits requiring intelligent caching (15-minute intervals)
- **Network Dependency**: Requires internet connection for stock data updates
- **Python Dependency**: External Python script dependency for data fetching
- **Currency Conversion**: Complex handling of GBX/GBP conversion for UK stocks
- **Memory Management**: Careful handling of Combine subscriptions and status bar items
- **Threading**: Network operations on background threads with UI updates on main thread

**Architecture Patterns:**
- **MVVM Pattern**: DataModel as ViewModel, SwiftUI views for preferences
- **Observer Pattern**: Combine publishers for reactive data flow
- **Repository Pattern**: NetworkService abstraction for data fetching
- **Caching Strategy**: Time-based caching with failure retry logic
- **Persistent Storage**: UserDefaults-based storage for configuration and last successful data