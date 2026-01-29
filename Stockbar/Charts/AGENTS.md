# STOCKBAR CHARTS KNOWLEDGE BASE

**Architecture:** Swift Charts | **Concurrency:** MainActor UI + async processing
**Domain:** Performance visualization, OHLC charts, menu bar sparklines.

## OVERVIEW
Chart components optimized for 60 FPS rendering and macOS menu bar integration. Heavy data work is offloaded to background tasks before binding into SwiftUI charts.

## STRUCTURE
- **PerformanceChartView.swift**: Main analytics dashboard with series comparison and range selection.
- **CandlestickChartView.swift**: OHLC chart with indicator overlays (RSI, MACD).
- **MenuPriceChartView.swift**: Compact chart for status menu popovers.
- **SparklineView.swift**: Reusable miniature trend line.
- **SparklineMenuView.swift**: NSView wrapper for menu bar embedding.
- **VolumeChartView.swift**: Volume histogram + price-at-volume overlays.
- **ChartInteractionManager.swift**: Centralized zoom/pan/crosshair state (`@MainActor`).
- **ChartGestureHandler.swift**: Option+Scroll zoom and magnification handling.

## CONVENTIONS
- **Downsampling**: Always reduce datasets >1000 points before rendering.
- **Async Processing**: Use `Task.detached` for normalization/filtering.
- **Dynamic Domains**: Use buffered Y-scale (5-10%) to avoid clipping.
- **Interaction**: Use `ChartInteractionManager` for coordinate conversions.

## ANTI-PATTERNS
- Feeding raw large datasets directly into `Chart`.
- Running indicator calculations in `body`.
- Hardcoded axis domains.
