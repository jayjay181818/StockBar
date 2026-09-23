# Python bridge

- `NetworkService.swift` implements the app's JSON protocol, arguments and per-operation timeouts. `PythonProcessRunner.swift` owns spawning, cancellation and pipe draining through `ProcessDataBuffer`; reuse it.
- Route symbols through `PythonConfiguration` validation/sanitization before constructing arguments. Preserve the provider-access gate.
- App quotes use `--json`. Human-readable legacy CLI output is not an app protocol; do not add regex fallbacks.
- Keep stdout/stderr drained independently and cancel timeout work after process exit. Preserve placeholder result metadata on failures.
- Use stub services in tests. Read [Python backend guidance](../../Resources/AGENTS.md) when changing both sides of the protocol.
