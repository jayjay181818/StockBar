# Charts

- Chart interaction (hover, zoom, pan) lives in `PerformanceChartView`; keep UI-facing state on `@MainActor`.
- Prepare and downsample large series outside chart bodies using established processing paths. Preserve cancellation and actor isolation; do not introduce `Task.detached` by default.
- Keep axes appropriate to the selected series and range. Calculate indicators only when needed.
- Keep Folync and legacy history series separate. Check empty/sparse data, range changes and hover/zoom behavior when affected.
