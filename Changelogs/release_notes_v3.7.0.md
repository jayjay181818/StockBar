# StockBar v3.7.0 Release Notes

**Status:** Implemented  
**Date:** 2026-11-11

Stockbar now updates itself, and keeps every credential in one Keychain item so macOS asks for access once after an update, not once per credential. Figures, charts, the Python pins and the database model are the same as in 3.6.0.

## After updating

- **This update is installed by hand**, as before: 3.6.0 and earlier have no updater. Download `Stockbar-3.7.0.zip` from the release page, unzip it and move Stockbar to Applications. Later versions arrive through **Settings → General → Updates**.
- **First launch of a downloaded copy**: macOS blocks it until you choose **Open Anyway** in System Settings → Privacy & Security. This is needed once per Mac. Updates installed by Stockbar are not blocked.
- **Keychain prompts**: the first launch asks for access to each credential saved by the earlier version, to move it into the new single item. Choose **Always Allow** each time. After later updates macOS asks once.
- **Going back to an earlier version** means entering the Folync token, Trading 212 credentials and API keys again: earlier versions do not read the new item.

## Updates

- Stockbar checks for new versions and installs them, using [Sparkle](https://sparkle-project.org). Downloads come from this repository's GitHub releases. An update is installed only if it is signed with Stockbar's update key.
- **Settings → General → Updates** has the channel, a switch for automatic checks and **Check Now**.
- Two channels: **Stable** receives released versions. **Testing** also receives a build of every change as it is merged, before it is released. Moving from Testing back to Stable takes effect at the next released version.
- No profile of your Mac is sent when checking.
- Builds are made by GitHub Actions and signed without an Apple developer account. That is why a downloaded copy needs **Open Anyway** once, and why macOS asks for Keychain access again after each update.

## Keychain

- The Folync token and its server, the FMP and Twelve Data API keys and the Trading 212 credentials are kept in one Keychain item, "Stockbar credentials". One item means one prompt after an update.
- Credentials saved by earlier versions are imported the first time they are needed. The old items are removed only after the new item has been written and read back. If a prompt is refused, nothing is removed and Stockbar tries again at the next launch.
- Checking whether a credential is stored still does not read it, so it never raises a prompt.

## For developers

- A release workflow builds a testing build for every merge into `testing` and a stable release for every version tag, and keeps the signed update feed on the `appcast` branch. See "Release builds and updates" in `Docs/Development.md`.
- CI packages the Release build the same way the release workflow does.
