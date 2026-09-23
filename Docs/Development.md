# Development workflows

Read [shared instructions](../AGENTS.md) first. This reference is needed for running checks or changing tooling; routine edits do not require the architecture and contributing guides too.

## Setup and sources of truth

Use the existing Xcode installation and Python environment. Deployment/language settings live in [the Xcode project](../Stockbar.xcodeproj/project.pbxproj), dependency pins in [requirements.txt](../Stockbar/Resources/requirements.txt), lint rules in [.swiftlint.yml](../.swiftlint.yml), and required gates in [CI](../.github/workflows/ci.yml). The project enables strict concurrency; do not infer Swift language mode from a toolchain version.

If dependencies need installation, use `python3 -m pip install -r Stockbar/Resources/requirements.txt` in the intended environment. Do not install or upgrade packages as part of an unrelated change. Use the shared commands below.

## Commands

Run from the repository root. [script/develop.sh](../script/develop.sh) is shared by local work and CI:

| Command | Behavior |
| --- | --- |
| `bash script/develop.sh build` | Debug build with signing disabled; no launch or process termination |
| `bash script/develop.sh test StockbarTests/CacheCoordinatorTests` | Run the selected test class; append `/methodName` to select one method |
| `bash script/develop.sh test` | Full XCTest suite |
| `bash script/develop.sh python-tests` | Compile Python syntax with bytecode outside Resources; run offline unit tests |
| `bash script/develop.sh checks` | SwiftLint, entitlements, Sendable allowlist, code invariants and documentation validation |
| `bash script/develop.sh docs-check` | Local documentation links, duplicate instruction names and advisory size limits |
| `bash script/develop.sh analyze` | Xcode static analysis |
| `bash script/develop.sh acceptance /path/to/manifest.json` | Existing isolated Folync acceptance harness |
| `bash script/develop.sh run` | Normal signed build and explicit launch |

Each invocation prints its private full-log path and final result; failures include up to 15 error lines and a short tail (or the last 60 lines if no error lines match), retaining the original exit code. Default logs, SwiftLint cache and DerivedData are under ignored `build/`. `PYTHON`, `STOCKBAR_LOG_DIR` and `STOCKBAR_DERIVED_DATA` override their respective defaults. Concurrent agents must use different DerivedData directories. Successful logs remain available for inspection; CI uploads them as artifacts.

Run the smallest affected checks first. Broaden for changes to shared behavior or required pre-publication gates. Documentation-only changes need `docs-check`; tooling changes need shell syntax checks and `python3 -B -m unittest discover -s Scripts/tests -p 'test_*.py'`. This avoids requiring an app build for every prose edit.

## Runtime and test isolation

The build/test commands do not launch the normal app deliberately, but XCTest may launch its configured host. Tests must inject isolated defaults, temporary/in-memory databases and stub providers. `StockbarRuntimeStorage.userDefaults` returns standard defaults outside acceptance; the wrapper itself is not proof of isolation. Set runtime configuration before its first access or use injected dependencies. Existing suite isolation must be checked before claiming a test run cannot affect user data.

The acceptance harness requires an existing manifest below the operating-system temporary directory, a mode-0600 token file beside it, and a loopback HTTP endpoint. The Focused tests desktop action requires `STOCKBAR_TEST_FILTER=StockbarTests/ClassName[/methodName]`; use the terminal command when selecting an ad hoc filter. Use `STOCKBAR_ACCEPTANCE_MANIFEST` for the desktop action or pass a manifest path on the command line. It builds a distinct acceptance bundle, disables live providers, isolates storage, and retains preflight/bootstrap evidence. It remains attached while its app runs; the log identifies the PID and evidence root. Startup is only a smoke check: verify the requested behavior before claiming acceptance. Never include tokens in reports.

[build_and_run.sh](../script/build_and_run.sh) preserves `run`, `--debug`, `--logs`, `--telemetry` and `--verify`. It refuses to run while Stockbar is already running; quit the app explicitly when a relaunch is intended. It never kills an existing process. `--verify` checks startup only and leaves the normal app running. Normal launches may refresh providers and use real app data.

## Project layout

The app source folder is synchronized into Xcode. New app Swift files compile automatically; new XCTest Swift files require explicit project membership. Internal agent docs must remain excluded from app resources. Directory `AGENTS.md` files contain local exceptions, while [architecture](Architecture.md) contains background explanations. Keep one canonical instruction file per directory; tool adapters point to shared guidance.

## Logs and recovery

Normal logs resolve to `~/Library/Logs/<bundle-id>/stockbar.log` with rotation; acceptance logs use its temporary root. Diagnostics in the main window also displays logs. Use [backup/restore procedures](../Scripts/README.md) for recovery; file backups do not export broker/Folync Keychain credentials.
