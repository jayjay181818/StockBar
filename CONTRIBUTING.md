# Contributing to Stockbar

Thanks for helping. This page is the short version; commands and current
details are in [Docs/Development.md](Docs/Development.md), and the rules the
code must keep are in [AGENTS.md](AGENTS.md).

## Setting up

You need macOS 15.4 or later and a current Xcode. Market-data features use
Stockbar's own Python environment, which `bash script/setup_python_env.sh`
creates; Trading 212 and Folync work without it.

```bash
bash script/develop.sh build          # compile, no launch
bash script/develop.sh test           # full XCTest suite
bash script/develop.sh python-tests   # offline Python tests
bash script/develop.sh checks         # lint, invariants, docs
```

## Making a change

1. Branch from `testing` and open a pull request into `testing`. Do not push
   to `testing` or `main` directly.
2. Keep the change focused, and add or update a test that would fail without
   it. New XCTest files need adding to the test target in Xcode; app source
   files are picked up automatically.
3. Run the four commands above before you push. CI runs the same ones.
4. Describe what changed and how you checked it. Say plainly what you did not
   check.

## Rules that matter most

- UI state belongs on the main actor; Core Data writes go through background
  contexts.
- Log through `Logger`, never `print`, so credentials are redacted.
- Figures from a broker or Folync are authoritative: do not recompute or
  blend them with other sources.
- UK prices quoted in pence are converted to pounds once, where the quote is
  read.
- Never commit credentials, tokens, private hostnames, personal paths or real
  portfolio data. Search your diff before you push.

## Reporting bugs and asking for features

Open a GitHub issue with the Stockbar and macOS versions, what you did, what
you expected and what happened. Attach redacted logs from the Debug Logs
screen if they help. For security problems, see [SECURITY.md](SECURITY.md).
