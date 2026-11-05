# Analytics

- Keep calculations independent of UI, live providers and persistence; accept inputs and return immutable results.
- Preserve existing actor isolation and financial semantics. Use `Double` consistently with surrounding code and tolerance-based assertions.
- Test empty inputs, missing/nonfinite prices, currency normalization and meaningful financial boundaries for affected calculations.
- Treat performance numbers as benchmark targets, not guaranteed behavior; use a reproducible workload before claiming an improvement.
