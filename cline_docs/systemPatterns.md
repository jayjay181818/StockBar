# System Patterns

This file describes how the system is built, key technical decisions, and architecture patterns.

**How the system is built:**
The system is built as a native macOS menu bar application using Swift with a hybrid architecture:

- **Swift Frontend**: Handles UI, data management, and user interactions
- **Python Backend**: Dedicated script for stock data fetching using yfinance
- **Reactive Data Flow**: Combine framework for real-time UI updates
- **Persistent Storage**: UserDefaults for configuration and last successful data
- **Menu Bar Integration**: Native AppKit status items for each tracked stock

**Key technical decisions:**
- **Hybrid Language Approach**: Swift for UI/logic, Python for data fetching to leverage yfinance ecosystem
- **Persistent Data Strategy**: Save last successful stock data to survive app restarts and network failures
- **Intelligent Caching**: 15-minute refresh intervals with 5-minute retry for failures to minimize API calls
- **Currency Normalization**: Automatic GBX to GBP conversion for UK stocks to ensure consistent calculations
- **Reactive UI**: Combine publishers for automatic UI updates when data changes
- **Graceful Degradation**: Show last known good data when network requests fail
- **Individual Status Items**: Separate menu bar items for each stock rather than a single aggregated view

**Architecture patterns:**
- **Model-View-ViewModel (MVVM)**: DataModel serves as ViewModel with @Published properties
- **Observer Pattern**: Combine publishers/subscribers for data flow
- **Repository Pattern**: NetworkService abstraction with PythonNetworkService implementation
- **Strategy Pattern**: Different handling for USD vs GBP/GBX currencies
- **Command Pattern**: Menu actions trigger async data refresh operations
- **Singleton Pattern**: Shared DataModel and Logger instances
- **Factory Pattern**: Status item controllers created dynamically for each stock
- **Cache-Aside Pattern**: Check cache first, fetch from network if needed, update cache on success