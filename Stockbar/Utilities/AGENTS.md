# STOCKBAR UTILITIES KNOWLEDGE BASE

**Architecture:** Infrastructure & Cross-Cutting Services
**Domain:** Logging, caching, performance monitoring, configuration.

## OVERVIEW
Shared utilities are leaf dependencies: thread-safe, minimal imports, reusable across Data/Services/Views without pulling UI or business logic into this layer.

## STRUCTURE
- **Logger.swift**: Actor-based async logging with file rotation.
- **CacheManager.swift**: Tiered cache (Memory/Disk/Archive) with LRU eviction.
- **PerformanceMonitor.swift**: Actor for timing and memory alerts.
- **ConfigurationManager.swift**: Singleton for API keys and provider settings.
- **ExportManager.swift**: CSV/PDF portfolio export.
- **Color+Hex.swift**: Color parsing extensions.

## CONVENTIONS
- **Actor/Singleton**: Use `await` on Logger/PerformanceMonitor; access managers via `.shared`.
- **No High-Level Imports**: Utilities must not import SwiftUI views or Services logic.
- **File IO**: Prefer Logger/CacheManager instead of ad-hoc FileManager writes.

## ANTI-PATTERNS
- UI controllers or view logic in Utilities.
- Portfolio calculations or network logic here.
