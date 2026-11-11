# Development workflows

Read [shared instructions](../AGENTS.md) first. This reference is needed for running checks or changing tooling; routine edits do not require the architecture and contributing guides too.

## Setup and sources of truth

Use the existing Xcode installation and Python environment. Deployment/language settings live in [the Xcode project](../Stockbar.xcodeproj/project.pbxproj), dependency pins in [requirements.txt](../Stockbar/Resources/requirements.txt), lint rules in [.swiftlint.yml](../.swiftlint.yml), and required gates in [CI](../.github/workflows/ci.yml). The project enables strict concurrency; do not infer Swift language mode from a toolchain version.

If dependencies need installation, use `bash script/setup_python_env.sh` for Stockbar's own environment (which the app uses automatically), or `python3 -m pip install -r Stockbar/Resources/requirements.txt` in another intended environment. [requirements.lock](../Stockbar/Resources/requirements.lock) holds every package those pins pull in, at an exact version with checksums; Stockbar's own environment and CI install from it. After changing `requirements.txt`, run `bash script/update_python_lock.sh` (needs uv) and commit both files; CI fails when they disagree. A weekly workflow opens a pull request that moves the locked packages to releases at least a week old. Do not install or upgrade packages as part of an unrelated change. Use the shared commands below.

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
| `bash script/develop.sh build-release` | Release build with signing disabled; CI runs it so the released configuration is always compiled |
| `bash script/develop.sh coverage` | Full XCTest run with code coverage; prints overall line coverage and the largest files with the least |
| `bash script/develop.sh acceptance /path/to/manifest.json` | Existing isolated Folync acceptance harness |
| `bash script/develop.sh run` | Normal signed build and explicit launch |

Each invocation prints its private full-log path and final result; failures include up to 15 error lines and a short tail (or the last 60 lines if no error lines match), retaining the original exit code. Default logs, SwiftLint cache and DerivedData are under ignored `build/`. `PYTHON`, `STOCKBAR_LOG_DIR` and `STOCKBAR_DERIVED_DATA` override their respective defaults. Concurrent agents must use different DerivedData directories. Successful logs remain available for inspection; CI uploads them as artifacts.

Run the smallest affected checks first. Broaden for changes to shared behavior or required pre-publication gates. Documentation-only changes need `docs-check`; tooling changes need shell syntax checks and `python3 -B -m unittest discover -s Scripts/tests -p 'test_*.py'`. This avoids requiring an app build for every prose edit.

## Runtime and test isolation

The build/test commands do not launch the normal app deliberately, but XCTest may launch its configured host. Tests must inject isolated defaults, temporary/in-memory databases and stub providers. Under XCTest, `StockbarRuntimeStorage` creates its own temporary root and defaults suite for the process (`xctest-…`) and removes them at exit, so the suite does not read or write the real app's defaults, files or Keychain items. Outside XCTest and acceptance it returns standard defaults. State set through it still carries from one test to the next within a run, so a test that changes a default restores it or uses an injected store.

The acceptance harness requires an existing manifest below the operating-system temporary directory, a mode-0600 token file beside it, and a loopback HTTP endpoint. The Focused tests desktop action requires `STOCKBAR_TEST_FILTER=StockbarTests/ClassName[/methodName]`; use the terminal command when selecting an ad hoc filter. Use `STOCKBAR_ACCEPTANCE_MANIFEST` for the desktop action or pass a manifest path on the command line. It builds a distinct acceptance bundle, disables live providers, isolates storage, and retains preflight/bootstrap evidence. It remains attached while its app runs; the log identifies the PID and evidence root. Startup is only a smoke check: verify the requested behavior before claiming acceptance. Never include tokens in reports.

[build_and_run.sh](../script/build_and_run.sh) preserves `run`, `--debug`, `--logs`, `--telemetry` and `--verify`. It signs with the first valid Apple Development identity in the login keychain so macOS keeps Keychain access decisions across rebuilds; set `STOCKBAR_SIGNING_IDENTITY` to a certificate name or SHA-1 to choose one, or to `adhoc` to opt out. No team ID is stored in the project. It refuses to run while Stockbar is already running; quit the app explicitly when a relaunch is intended. It never kills an existing process. `--verify` checks startup only and leaves the normal app running. Normal launches may refresh providers and use real app data.

## Project layout

The app source folder is synchronized into Xcode. New app Swift files compile automatically; new XCTest Swift files require explicit project membership. Internal agent docs must remain excluded from app resources. Directory `AGENTS.md` files contain local exceptions, while [architecture](Architecture.md) contains background explanations. Keep one canonical instruction file per directory; tool adapters point to shared guidance.

## Branches, releases and dependencies

Work on a branch and open a pull request into `testing`; do not push to `testing` or `main` directly. CI runs on every pull request to either branch. To release, run `bash script/release.sh X.Y.Z` on a branch: it sets `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project and the version line at the foot of the README, and stops if `Changelogs/release_notes_vX.Y.Z.md` or the README release-history entry is missing. `checks` fails when those places disagree. After the pull request is merged, tag `vX.Y.Z` (annotated) on the merge commit in `testing` and push the tag: the [release workflow](../.github/workflows/release.yml) builds the app and publishes the GitHub release with the release notes as its body (see [Release builds and updates](#release-builds-and-updates)). Then bring `main` up to date with a pull request from `testing`.

[Dependabot](../.github/dependabot.yml) opens weekly, grouped pull requests into `testing` for GitHub Actions and the pinned Python helper packages. The pins target Stockbar's own environment (Python 3.13; 3.10 is the minimum). The launch-time check reads `name==version` pins and understands only plain `python_version` markers (see `PythonRequirements.swift`). CI runs the Python tests on 3.13; check they pass before merging any helper update. `setup_python_env.sh` downloads a pinned uv when no uv or Python 3.10+ is installed; to update it, change `UV_VERSION` and both `UV_SHA256_*` values together from the release's `.sha256` files, and never remove the checksum check. `Scripts/tests/test_setup_python_env.py` covers the download offline.

Before publishing, search the diff for credentials, tokens, private hostnames, personal paths and real portfolio data. Private notes belong in ignored files (see [.gitignore](../.gitignore)).

## Release builds and updates

Stockbar updates itself with [Sparkle](https://sparkle-project.org). Everything runs on GitHub: Actions builds the app, Releases hosts the downloads, and the list of updates (the feed) is a file in this repository. There is no Apple developer account, and no name or address of a person goes into a build.

**What gets built.** The [release workflow](../.github/workflows/release.yml) runs on three kinds of push:

| Push | Result |
| --- | --- |
| to `testing` (a merged pull request) | A testing build, published as the prerelease `testing-<build>` and offered on the Testing channel |
| of a tag `vX.Y.Z` | A stable release: `Stockbar-X.Y.Z.zip` attached to the release for the tag, with `Changelogs/release_notes_vX.Y.Z.md` as its notes, offered on both channels |
| to a `release-test/…` branch | A dry run: built and signed the same way, kept for a week as a workflow artifact, nothing published |

**Build numbers.** A stable build is the version without dots (3.6.0 is 360). A testing build is the build of the last version tag, a dot, and the number of commits since that tag (360.14). Sparkle compares the parts as numbers, so 360 < 360.14 < 370. A testing build keeps the old base until the new tag exists, even after `release.sh` has moved the project to the next version. The workflow refuses a version tag that disagrees with the project or is on neither `testing` nor `main`, and refuses a testing build when the newest version tag is missing from the history of `testing`: that build would sort below the release and never be offered. Keep `testing` up to date with whatever carries the newest tag.

**Signing the app.** [package_release.sh](../script/package_release.sh) builds the Release configuration, signs it ad hoc with the hardened runtime, zips it, then unpacks the archive and checks that the app starts. Ad hoc signing has three consequences:

- macOS blocks the first launch of a downloaded copy until the user chooses **Open Anyway** (once per Mac). Updates installed by Sparkle are not blocked.
- macOS asks for Keychain access again after every update, once per saved credential. A self-signed certificate was tried and does not help: for any signature not issued by Apple, macOS ties Keychain access to the exact build.
- The hardened runtime refuses to load a framework from another signer unless library validation is off, and an ad hoc build has no signer in common with the Sparkle framework inside it. [Stockbar.entitlements](../Stockbar/Stockbar.entitlements) therefore carries `com.apple.security.cs.disable-library-validation`, the only entitlement [validate_entitlements.sh](../Scripts/validate_entitlements.sh) allows.

The script refuses to package a build whose signature names a certificate or a team, or whose binaries contain a home-folder path other than the build runner's. Do not sign a release with an Apple Development certificate: on a free account its name contains the Apple ID.

**Signing the update.** Sparkle accepts an update only if it is signed with the EdDSA key whose public half is `SUPublicEDKey` in [Info.plist](../Stockbar/Info.plist). The private half is the Actions secret `SPARKLE_ED_PRIVATE_KEY`; the owner keeps the original in their login Keychain (Sparkle's `generate_keys`, account `stockbar`). Keep a backup. Without the key no installed copy can be updated again, and anyone holding it can sign an update those copies will accept. To put the key back into the secret, export it to a file with `generate_keys --account stockbar -x <file>`, run `gh secret set SPARKLE_ED_PRIVATE_KEY < <file>`, and delete the file. [sign_release.sh](../script/sign_release.sh) signs the archive, checks the signature against the key inside that archive's own app ([verify_update_signature.swift](../script/verify_update_signature.swift)) so a wrong secret fails before anything is published, adds the build to the feed and signs the feed.

**The feed.** `appcast.xml` lives alone on the `appcast` branch, which only the workflow writes and never force-pushes. The app reads it from the address in `SUFeedURL` and, because `SURequireSignedFeed` is on, ignores a feed whose signature does not match; editing the file by hand breaks it for everyone. [release_feed.py](../Scripts/release_feed.py) keeps the 3 newest stable and 10 newest testing builds and drops testing builds older than the newest stable one. The workflow then deletes the `testing-*` prereleases and tags the feed no longer lists. To withdraw a build, publish a newer one: Sparkle never moves to a lower build number.

**In the app.** [AppUpdateService.swift](../Stockbar/Services/AppUpdateService.swift) owns the updater. It stays off in Debug builds, in test and acceptance runs (unless the feed is on this Mac), and in a bundle with no feed address or key. Sparkle is pinned to an exact version in the project; `Package.resolved` is tracked so release builds resolve the same sources. To update Sparkle, change the version in the project and commit the new `Package.resolved`.

**Trying it locally.** `bash script/package_release.sh --build 360.1 --output build/release` produces the same archive the workflow does. `Scripts/tests/test_release_feed.py` covers build numbering and the feed. To try an update end to end, build two archives with different build numbers and a feed address on `127.0.0.1`, sign them with a throwaway key, and serve the feed locally; never use the real key or the real feed for a trial.

## Logs and recovery

Normal logs resolve to `~/Library/Logs/<bundle-id>/stockbar.log` with rotation; acceptance logs use its temporary root. Diagnostics in the main window also displays logs. Use [backup/restore procedures](../Scripts/README.md) for recovery; file backups do not export broker/Folync Keychain credentials.
