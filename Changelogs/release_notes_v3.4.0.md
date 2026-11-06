# StockBar v3.4.0 Release Notes

**Status:** Implemented  
**Date:** 2026-11-06

A minor release that makes the Folync connection usable with VoiceOver. No stored data changes, and the Python pins are the same as in 3.3.0.

## VoiceOver and Folync

- In **Settings → Connections**, VoiceOver reads the Folync status line as **Folync status** with the current message, and the progress spinner as **Folync request in progress**.
- The results of **Test Connection**, **Preview**, **Activate Folync** and **Disable Folync** are spoken, even when a result repeats the previous one. Activation is confirmed with "Folync is active."
- Folync is checked every minute, so background checks stay quiet unless something is wrong. A problem is announced once, and again only after the connection recovers or the problem changes. A rate-limit countdown counts as one problem.
- **Waiting for Keychain access** is announced, because you need to answer the macOS prompt.
- **Refresh Now** shows the progress spinner while it runs and always answers with "Refresh complete." and the outcome. The next background check does not repeat it.
- Announcements are made only while the Folync settings are on screen.

## Development

- `FolyncStatusAnnouncementTests` covers when the status is and is not announced (5 tests).
- `Docs/Remediation_Plan_*.md` files are no longer tracked; they stay local, like the findings archive.

## Comparison basis

These notes cover the changes on `testing` after tag `v3.3.0`.
