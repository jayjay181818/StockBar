# Technical Context

This file describes the technologies used, development setup, and technical constraints of the project.

**Technologies used:**
The project primarily uses Swift, AppKit, and Foundation. It also utilizes a Python script (`get_stock_data.py`) for fetching stock data.

**Development setup:**
Development is likely done using Xcode. The project structure follows standard macOS application conventions.

**Technical constraints:**
A technical constraint is the reliance on an external Python script for data fetching. There is also a 30-second delay implemented between batch requests in the network service, likely to avoid rate limiting from the data source.