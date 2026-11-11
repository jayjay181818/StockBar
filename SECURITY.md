# Security

## Reporting a problem

Please report a suspected vulnerability privately, through
[GitHub's private vulnerability reporting](https://github.com/jayjay181818/StockBar/security/advisories/new),
rather than in a public issue. Say what you found, how to reproduce it and
which version you were running. Expect a first reply within a week.

Do not include real API keys, tokens, account numbers or portfolio data in a
report. Diagnostic logs are redacted when written, but check them before
sharing.

## Supported versions

Only the latest release receives fixes.

## What Stockbar stores

- Trading 212 credentials and the Folync client token: macOS Keychain.
- Financial Modeling Prep and Twelve Data API keys: a settings file in
  Application Support, readable only by your account. The Python helper reads
  it, which is why these keys are not in the Keychain.
- Portfolio data, history and backups: local files only.

Stockbar's Trading 212 access is read-only. It never places orders and does
not need the *Orders - Execute* permission.
