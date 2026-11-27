# Stockbar User Guide

Stockbar tracks a stock portfolio from the macOS menu bar, with a main window for holdings, analysis, alerts and settings.

## Contents

- [Installing](#installing)
- [Getting started](#getting-started)
- [The main window](#the-main-window)
- [Activity](#activity)
- [Holdings](#holdings)
- [The menu bar](#the-menu-bar)
- [Analysis](#analysis)
- [Alerts](#alerts)
- [Currencies and UK stocks](#currencies-and-uk-stocks)
- [Connections: Trading 212 and Folync](#connections-trading-212-and-folync)
- [Refreshing and data freshness](#refreshing-and-data-freshness)
- [Updates](#updates)
- [Backups, Data Health and Diagnostics](#backups-data-health-and-diagnostics)
- [Troubleshooting](#troubleshooting)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Privacy](#privacy)

## Installing

1. Download `Stockbar-<version>.zip` from the [latest release](https://github.com/jayjay181818/StockBar/releases/latest) and unzip it.
2. Move **Stockbar** to your Applications folder before you open it. Until it is moved, macOS runs a downloaded app from a read-only copy, where it cannot update itself.
3. Open it. macOS refuses the first time, because the app is not notarised by Apple. Open **System Settings → Privacy & Security**, scroll down to **Security** and choose **Open Anyway**. This is needed once per Mac, not after each update.

If you prefer the terminal, this does the same as step 3:

```bash
xattr -dr com.apple.quarantine /Applications/Stockbar.app
```

Stockbar then keeps itself up to date; see [Updates](#updates).

## Getting started

**Requirements:** macOS 15.4 or later and an internet connection for market data. Stockbar sets up its own Python (below); nothing needs installing first. Another interpreter must be Python 3.10 or later; Apple's `/usr/bin/python3` 3.9 is no longer supported.

Stockbar uses the interpreter in the `pythonInterpreterPath` setting if there is one; otherwise its own environment at `~/Library/Application Support/Stockbar/python-env`. Until that environment is set up, market data from Python providers is unavailable.

Open **Settings → Advanced → Python** and choose **Set Up**. Stockbar installs a current Python and its pinned packages in its own environment and uses it from the next refresh. It uses `uv` or a Python 3.10 or later from Homebrew or python.org if one is installed; otherwise it downloads a pinned release of `uv`, checks its SHA-256, and keeps it and its Python in Stockbar's Application Support folder, so nothing needs installing first. It needs an internet connection. **Rebuild** reinstalls it.

On first launch, and again after an update changes the pinned versions, Stockbar checks the interpreter it uses. If the environment is not set up, or packages are missing or out of date, an alert offers **Set Up Automatically**, which does the same as the Settings button. For an interpreter set with `pythonInterpreterPath`, the alert also offers **Copy Command** and **Open Terminal**; Copy Command copies a ready-to-run command such as:

```bash
'/opt/homebrew/bin/python3' -m pip install -r '/Applications/Stockbar.app/Contents/Resources/requirements.txt'
```

If pip reports an *externally managed environment* (common with Homebrew Python), create a virtual environment, install the requirements into it, and point Stockbar at it (then relaunch):

```bash
defaults write com.stockbar pythonInterpreterPath "$HOME/stockbar-venv/bin/python3"
```

The dependency check runs again whenever the interpreter or the pinned versions change.

Stockbar appears both in the Dock and in the menu bar. Click the Dock icon or choose **Open Stockbar** (⌘O) to show the main window.

## The main window

The sidebar floats in its own panel on the left of the window and groups every screen:

| Group | Screens |
|---|---|
| Portfolio | **Overview** (value, today's and selected-period movement, chart, position inspector), **Holdings**, **Activity** (Folync portfolios only), **Alerts** |
| Analysis | **Charts**, **Income** (Folync's figures, or an estimate for other portfolios), **Calendar** (dividend and earnings dates), **Trades** (Folync portfolios only), **Risk**, **Allocation** (including Attribution) |
| System | **Data Health**, **Backups**, **Diagnostics**, **Settings** |

The page that used to be called Performance is now called **Charts**. Click the sidebar, or press Tab until it has focus, then use the Up and Down arrows to move through it, and Home and End to jump to the first and last screen. The bottom of the sidebar shows where your portfolio comes from (local, Trading 212 or Folync) and when prices last updated; its refresh button (⌘R) requests an immediate update and spins while it runs. If Folync stops answering while Stockbar shows the figures it saved, the bottom of the sidebar turns amber and says when those figures are from, for example "Couldn't reach Folync · figures from 14:05". Hide the sidebar with **View → Hide Sidebar** (⌃⌘S) or the sidebar button next to the window's close, minimise and zoom buttons; the page then takes the whole width, and Stockbar remembers your choice. The window remembers its size, position and last screen. Through the window you see a blurred, tinted view of what is behind it; System Settings → Accessibility → Display → Reduce Transparency makes it solid, and Increase Contrast outlines the sidebar. Motion follows Reduce Motion in the same place.

**Overview** shows the total value in large type, with today's change and the selected period's change beside it, a portfolio chart (hover to read any point) and details for one position. The periods are **1D**, **1W**, **1M**, **3M**, **1Y** and **All**, for every portfolio source; with a local or Trading 212 portfolio the longer ones show what Stockbar has stored. A change Stockbar does not know shows as "–" with the reason under it, such as **No current history from Folync**. The period's change is the difference between the first and last values in the chart, so money paid in or taken out during the period counts in it.

With Folync, a card under the chart shows what the total is made of: **Net deposits** (the figure **Measure P&L Against** uses), **Unrealised gains** and **Realised gains** as Folync reports them, and **Income, interest and fees**, which is everything else in the total: dividends, interest, fees and anything Folync does not split out. Stockbar cannot split that part further. The four figures always add up to the total shown. A part that is zero or negative has no length in the bar; its figure still shows, in red when negative, and a line under the bar says the bar shows the positive parts only. A figure Folync marks partial is labelled **Partial**. The card is shown only when Folync gives all four figures in the portfolio's currency; otherwise, and with a local or Trading 212 portfolio, the page shows a summary table instead.

When Folync stops answering and Stockbar is showing the figures it saved, an amber bar at the top of the Overview says **Couldn't reach Folync** and when the figures were saved, and the total says "as of" that time. If Folync answered but its figures could not be used, the bar says **Folync didn't send new figures** instead. It goes away when Folync answers again. It makes no request of its own.

## Activity

With a Folync portfolio, **Activity** lists every transaction Folync holds, newest first, under a heading for each month. Each row shows the day, the kind of transaction, the holding's ticker, the quantity and price as Folync gives them (in the transaction's own currency, with any commission and tax), and the amount in the portfolio's currency. Money in is green with "+", money out red with "−"; a transfer, split, note or corporate action has no sign. A figure Folync does not give shows as "–", and one Folync marks partial says so beside it. The kind switches, **Trades**, **Dividends**, **Interest** and **Cash** (deposits, withdrawals, transfers, fees, tax and notes), combine: click one to show or hide that kind, so one click hides the daily interest rows. Option-click a switch, or choose **Show Only** from its menu, to show that kind alone; **All** shows every kind again. Hiding the last kind shown also gives **All**. Stockbar remembers your choice. **As entered** or **Adjusted** restates quantities and prices for splits and similar events. Search shows one holding, by its ticker. **Load more** at the bottom fetches the next rows; the refresh button asks Folync again. The page asks Folync only when you open it, refresh it or load more, and reuses an answer from the last five minutes. If Folync is not answering, a saved copy is shown under an amber bar that says when it was saved. Activity is read-only: transactions are added and changed in Folync. With any other portfolio source the sidebar entry is dimmed with the reason **Needs a Folync portfolio**.

## Holdings

The read-only table shows your positions in your saved order; click the Instrument, Price or Weight header to sort. The **Amounts / Percent** switch beside the search field shows both **Today** and **Total gain** as amounts or as percentages, and Stockbar remembers the choice. Search filters the table without changing portfolio totals.

**Settings → Appearance → Show company logos** adds a logo beside each instrument and beside the ticker in its stock popover. When enabled, Stockbar sends visible ticker symbols to Financial Modeling Prep. Stockbar keeps the results in memory and shows a building icon for missing artwork.

**Weight** is a holding's share of the portfolio. With Folync it is Folync's own figure, shown as Folync gives it; otherwise it is the holding's value as a share of the net value above the table. A watchlist symbol, or a holding whose value is not known, shows "–". The line under the table counts holdings and watchlist symbols and says which weight you are seeing.

The strip above the table shows the **Net value** (with the US-dollar figure on a second line when you display another currency), **Total gains** with a line saying what they are (unrealised gains as Folync or Trading 212 report them, or Stockbar's own sum against average cost for a local portfolio), and the number of **Tracked symbols**.

Choose **Edit** to change local holdings, and **Done** when finished (changes save as you type):

- **Add Holding** adds a row. Enter the symbol in Yahoo Finance format (`AAPL`, `VOD.L`, `SHOP.TO`), units, average cost and the currency that cost was entered in. Fractional units are kept as entered.
- A symbol already in the portfolio is flagged with a warning; only one row per symbol is kept when saved, so combine lots into one row.
- Row actions: 👁 **watchlist only** (price shown, excluded from totals and analytics), move up/down, and remove. Removing a holding asks for confirmation.
- The **Menu Bar** switch (checkbox while editing) controls whether the symbol has its own menu-bar item. Profit and loss columns are shown outside Edit mode.

Positions provided by a linked Trading 212 account or by Folync are read-only here; their menu-bar visibility and alerts remain editable.

## The menu bar

**Portfolio item.** Shows total value and today's change. In Settings → Menu Bar → Portfolio Menu Bar choose the currency, decimal places and **Day Gain** format (*Amount and Percentage*, *Amount*, or *Percentage*); the preview matches the menu bar exactly. Click it for a popover with the total and its change over the chosen period, a chart for **Today**, **1 week** or **1 month** (on Today, a dotted line marks yesterday's close), **movers for the selected period**, and total return beside net deposits or cost basis. Today uses the holding’s daily change. The week and month compare its first and last observed prices when its history spans the period. Rows are sorted from biggest gain to biggest loss, with “–” for missing history. The list scrolls when the remaining screen height runs out. If Folync returns a partial portfolio chart, a change between two available values is labelled with their dates and **partial**. Hover over the chart to read the value at any point. With Folync, the chart first shows the history Stockbar saved from Folync's last answer, marked **Checking Folync**, and updates when Folync replies. If Folync doesn't answer, a saved chart stays up marked as a stale cache, and the Overview's period change says **No current history from Folync**; a period with nothing saved says **Couldn't reach Folync**, and so do the portfolio charts on the Charts page, next to their **Unavailable** badge.

**Total P&L.** With Folync as the portfolio source, total P&L in the portfolio popover and on the Overview (the total return beside "What … is made of", or the summary table when that card is not shown) is measured against **net deposits** by default: the money you paid in less what you took out, as Folync reports it. The portfolio value it is measured from includes cash, so sales, dividends, interest and fees all count. To measure it against the cost of the shares you hold instead, choose **Cost of Current Holdings** in Settings → General → **Measure P&L Against**. With a local or Trading 212 portfolio, or when Folync cannot give net deposits, total P&L is measured against cost basis. A new deposit can show as gain for up to about ten minutes; **Refresh Now** in Stockbar's Folync settings reads it at once. The menu bar item and the per-stock popovers are not affected.

**Per-stock items.** Each visible holding can have its own item. Choose a display mode and change format in Settings → Menu Bar, or a **Custom** template using these tokens:

| Token | Meaning |
|---|---|
| `{symbol}` | Ticker |
| `{price}` | Current price |
| `{change}` | Price change today |
| `{changePct}` | Percentage change today |
| `{dayPL}` | Today's profit/loss for your position |
| `{currency}` | Currency symbol |
| `{arrow}` | Up/down arrow |

Example: `{symbol} {price} {arrow}{changePct}`.

Click a stock item for its popover: a price chart (**24h**, **1 Week** or **1 Month**; the shortest range covers the last 24 hours rather than today's session) with an optional benchmark line (S&P 500 or FTSE 100; switch it off in Settings → Menu Bar → Stock Popover), market value, P&L and units. Hover over the chart to read the price at any point. A symbol without stored history shows **No history yet** rather than a flat line. For local holdings, the pencil next to **Units** edits the quantity (the current locale's decimal separator is accepted); a lock means the quantity comes from a linked source. If updates for the symbol have been paused after repeated failures, the popover says so and offers **Retry Now**.

**Next up.** Under the figures, the portfolio popover lists up to three dividend or earnings dates in the next 14 days, soonest first ("ULVR goes ex-dividend", "HSBA pays £38.20", "NVDA reports earnings"), each with its day and mark; the Overview shows the same as three cards under the chart. Both read only what Stockbar already saved for Income and Calendar, so opening them asks nothing: Next up is absent until one of those pages has loaded, and when nothing falls in the next 14 days.

Both popovers end with the last update time (click it to refresh) and buttons to open the Stockbar window, open Settings and quit. Popovers follow the **Theme** in Settings → Appearance.

Gains are green and losses red when **Color Coding** is on (Settings → General); unchanged or unknown values are neutral. **Market Indicators**, also in Settings → General and off by default, marks pre-market, after-hours and closed-market prices. Settings → Menu Bar → Menu Bar Visibility can hide all stock items or show them only when an external display is connected.

## Analysis

- **Charts** — portfolio value, gains or an individual stock over preset or custom ranges, as a line or candlestick chart with optional indicators and comparisons. On the 1 Day and 1 Week ranges the line chart draws nights and weekends narrow, so the hours with prices fill the chart; longer ranges are drawn to scale.
- **Income** — new. For a Folync portfolio: the dividends Folync expects in the next 12 months, with the declared and estimated parts, the yield and the income received as Folync gives them; a chart of the six months up to this one and the six after it; and the payments still to come, soonest first, with ex-dividend dates. **History** lists payments received, newest first; **By holding** sums each paying holding's payments over the chart's months. The chart's bars and the By holding sums are Stockbar's own sums of the payments Folync lists, and say so; a payment with no amount yet adds nothing and is counted under the chart. **Declared** or **Estimated** beside a payment appears only when Folync says which. The page asks Folync when you open it and when you click its refresh button, never on its own; switching between Outlook, History and By holding asks nothing, and opening it again within five minutes reuses the last answer. **Load more** fetches older payments when Folync has more. If Folync doesn't answer, the page shows its saved copy under an amber bar saying when it is from.

  With a local or Trading 212 portfolio, **Income** is an estimate, and says so at the top: each holding's dividends over the last year as Yahoo records them, times the units you hold today. It is not a record of what was paid to you, since Stockbar doesn't know what you held on each date. **Outlook** shows the estimate for the next 12 months (last year's payments repeated a year on), a chart of the last 12 months and the next 12, and the estimated payments, soonest first, each marked **Estimate**; where Yahoo gives a real upcoming ex-dividend date, that date replaces the estimated one and is marked **Yahoo's date, amount estimated**. **History** lists the last 12 months' payments at today's units, and **By holding** gives each holding's last and next 12 months and Yahoo's next date if it has one. Dates are ex-dividend dates. A holding with no payments shows **None**; one Yahoo has no answer for shows **–**; watchlist rows are left out. Amounts are converted into your currency only with exchange rates already loaded; a holding with no rate shows its own currency's figure, is left out of the totals, and the page says so. Yahoo is asked when you open the page and when you click its refresh button, never on its own; its answers are kept for a day, and after Yahoo limits requests Stockbar waits an hour. The sidebar entry is dimmed when live market data is off ("Needs live market data, which is off"), and while Folync is switched on but its portfolio is not showing yet ("Needs a Folync portfolio").
- **Calendar** — new. Dividend and earnings dates for your holdings, as a month grid (Monday first) and a list. **Upcoming** runs from this month to twelve months ahead, grouped **This week**, **Next week**, then by month; **Past** goes back twelve months, newest first, with the dividends and the earnings dates of those months. **All**, **Dividends** and **Earnings** choose what is shown, in either view. In the grid an open circle is an ex-dividend date, a filled circle a payment and a diamond earnings; an estimated date is drawn with a dashed outline and its symbol in italics, and more symbols than fit become "+2". Click a day, or reach it with the keyboard, to mark its events in the list; VoiceOver reads each such day as one sentence. For a Folync portfolio the dividends are Folync's, from the same answer as the Income page: each payment on its pay date, and its ex-dividend date as a row of its own ("Ex-dividend, pays 11 Dec, £58.40"), marked **Declared** or **Estimated** as Folync dates it, or **Upcoming** when Folync doesn't say; an amount Folync estimates reads "about £96.20". For a local or Trading 212 portfolio they are the Income page's estimate from Yahoo's record, and the page says so: every amount is "about", dates Stockbar estimated from last year are marked **Estimated**, and Yahoo's own dates have no mark (Yahoo doesn't say whether a date is declared). Earnings dates come from Yahoo for either portfolio: a single date is **Earnings**, a range shows on its first day as "expected between …" and is marked **Estimated**; a date already past is not shown in Upcoming, and the footer says how many holdings have no earnings dates. In **Past** each earnings date shows Yahoo's figures as Yahoo gives them, with no colour or verdict: "Earnings, EPS 1.52 against 1.48 expected" when Yahoo gives the reported and the expected earnings per share, "Earnings, EPS 1.52" when it gives only the reported one, and just "Earnings" when it gives neither; Yahoo's surprise follows when it gives one ("surprise 2.70%"). Yahoo gives a company's figures in the currency of its accounts, which it doesn't name and which may differ from the share's price currency (a London bank may report in dollars, a London-listed airline in euros), so by default they are shown without a currency, for every share. **Settings → Advanced → Earnings Figures** lists each holding Calendar asks Yahoo about, by the symbol it asks with, and lets you choose for each: **As Given** (the default), a currency, which then shows with the figures ("Earnings, EPS €0.27 against €0.28 expected, surprise -4.98%", and VoiceOver says "0.27 euros"), or **Hide Figures**, which leaves the date and Yahoo's surprise ("Earnings, surprise -4.98%"). A change shows in an open Calendar straight away without asking Yahoo again, a choice for a holding you no longer hold is kept in case it comes back, and the choices travel with **Export & Import**. With no holdings, or none Calendar can ask Yahoo about, the card says so in one line. Past earnings are asked for only while Past is shown: when you choose it and when you click refresh there; Upcoming, Next up, the popover and the Overview never ask for them. While they load, or if Yahoo is limiting requests or doesn't answer, the past dividends still show, with a note. Funds and investment trusts usually have no dates from Yahoo, so theirs are estimated from last year's payments and marked as such. The page asks when you open it and when you click its refresh button, never on its own; with Folync, opening Income or Calendar within five minutes of the other reuses the same answer. If Yahoo is limiting requests or doesn't answer, the dividends still show with a note. The sidebar entry is dimmed exactly when Income's is.
- **Trades** (new, Folync portfolios only) — every position you've opened and how it did, as Folync works it out: the win rate ("9 of 14 trades made money"), how often a trade beat the S&P 500 over the same days, Folync's total gain on trades, open and closed, and this year's fees. The table lists each lot with its status (Open, Partial, Closed), the day it was opened, how many days it was held, its cost, gain and return, and the points it finished ahead of or behind its index over the same days; "–" means Folync gave no figure. **All**, **Open**, **Partial** and **Closed** choose the lots; **Load more** asks for more rows; the refresh button asks Folync again. A card below shows a year's fees (one figure, as Folync gives it), what was bought and sold, and turnover, with a switch for earlier years. Stockbar asks Folync only when you open the page, refresh it or load more. If Folync doesn't answer, the copy saved last time is shown under an amber notice with its time. For a local or Trading 212 portfolio the entry is dimmed, because only Folync knows when you bought and sold. Nothing on the page changes anything in Folync.
- **Risk** — how bumpy the ride has been, from Stockbar's own stored portfolio history (for a Folync portfolio too, not Folync's history). A strip gives volatility, the Sharpe and Sortino ratios, each with a reading from "Poor" to "Exceptional", and the worst fall from a peak; a chart shows how far below its peak the portfolio stood each day, with the lowest point marked; "On a bad day" gives the 95% and 99% value at risk as a loss in the display currency; then the falls of more than 5%, the downside deviation and a footnote with the days, dates, method and risk-free rate behind the figures. Missing observations are ignored rather than treated as zero.
- **Allocation** — a donut beside its list, grouped by sector, by holding or by the currency each holding is priced in, even when Folync values it in another (pence count as pounds; past eight groups the smallest share one "Other" slice). Allocation values each holding as Holdings does (Folync's figure, the broker's for a Trading 212 position, otherwise price times units) and converts only at exchange rates Stockbar has loaded, working its figures out again as soon as rates arrive. When the portfolio's source gives its cash (Folync or Trading 212), each view also has a Cash row and slice, and every share is of the same total as Holdings' Weight column, so the two pages agree; a cash-only account is all Cash. There is no Cash row, and a line says the shares are of the holdings alone, when not every holding has a price yet, when the cash has no exchange rate, when Folync gives no total, when a Trading 212 account sits beside holdings kept outside it, or when the holdings and cash do not add up to the source's total. That check is made in the total's own currency at the exchange rates Stockbar has loaded (pence count as hundredths of a pound), and allows only the rounding that cannot change a percentage as shown; with no rate for one of the figures, cash is left out as having no exchange rate. A holding known to be worth nothing, or less, counts as valued and has no slice. Cash below zero has no slice and a line under the chart says so; cash that shows as zero is left out. Below the donut: the diversification score, concentration and recommendations (of the holdings alone); how the holdings move together, drawn as a grid of correlations over at least 20 shared trading days of stored prices (the twelve largest holdings; the summary figures cover them all), with the time range beside it; and performance attribution. Benchmarks and watchlist symbols are excluded.

History accumulates as Stockbar runs (Settings → Refresh → Chart Data Collection) and is backfilled where providers allow.

## Alerts

Alerts → **Add Alert** creates an alert when a price rises above or falls below a threshold, or moves from the previous close by a percentage; the sheet shows the symbol's current price for reference. Above and below alerts fire when the price crosses the level, so the sheet warns if the price is already past it. Alerts work for every holding, including ones priced by Folync or Trading 212. Alerts are delivered as macOS notifications; allow notifications for Stockbar when prompted. Each row shows the condition, the price now (none for a symbol no longer held) and when it last fired; a paused alert is greyed and marked **Paused**. Existing alerts can be edited (**Edit Alert…**), paused, resumed or deleted from their row or its right-click menu. An alert that has fired does not fire again for 15 minutes.

## Currencies and UK stocks

Choose the **Preferred Currency** in Settings → General (USD, GBP, EUR, JPY, CAD, AUD). Positions keep their own currencies and are converted for totals. Exchange rates and when they were last obtained are shown in Settings → General → Exchange Rates.

London prices are often quoted in pence (**GBX**, 100 GBX = £1). Stockbar converts pence to pounds once, when data arrives, and displays pounds. When entering an average cost, pick the currency you are typing in — **GBX** for `250` meaning 250p, or **GBP** for `2.50`.

## Connections: Trading 212 and Folync

Settings → **Connections** manages optional sources. Credentials are stored in your Keychain. From the top: **Market-data keys**, the Folync card, the Trading 212 card and **Fetch order**. Every Settings tab runs the full width of the window, in cards.

- **Trading 212** — off until you switch on **Enable Trading 212**. While a Folync portfolio is active, the card is inactive and says so at its top right. Choose the environment (**Demo / Paper** by default, or **Live / Real Money**) and the account type (Stocks & Shares ISA by default, or Invest; CFD accounts are not supported by Trading 212's API). Link a read-only account, preview matches and differences, then link holdings. Linked positions take quantity, price, average cost and P&L from the broker. **Import Broker-Only Holdings** adds positions you have not entered by hand. Linked holdings sync every five minutes by default; **Sync Linked Holdings** and **Reconcile Holdings Now** act at once. An account with nothing linked, such as one holding only cash, is valued from its account summary on the same schedule when you have no holdings of your own in Stockbar: Holdings, the menu bar and the popover show its value, and Allocation shows its cash. Beside holdings you entered yourself it is left out, and your own holdings' totals and weights stay as they are; links in another environment or account type do not count as links in this one. With no rows to list, Holdings says its total is the Trading 212 account's value. Allocation shows the cash as the whole account only when they agree; when the account also holds investments not linked, it says the cash does not add up to the total. Without a figure for the account's investments, the Overview shows its cost basis and unrealised P&L as unknown. Changing or clearing the credentials, switching Trading 212 off, or choosing another environment or account type drops the old account's figures at once; while a Folync portfolio is active no Trading 212 figure is used. An hourly check that applies holding changes, automatic import of new positions during it, and deleting holdings that disappear from Trading 212 are each off until you switch them on.
- **Folync** — use a self-hosted Folync instance as the authoritative portfolio. While active, local holdings are kept aside and restored when you switch back. The card's top right says **Active**, or **Enabled** while Folync is switched on but not showing its portfolio, and a line under the buttons gives the last and next check ("Last checked 15:42, next 15:43"). Under **What Stockbar reads from Folync**, each kind of data has its own checkbox with Folync's status beside it: **Ready**, **Not ready** with the reason, **Unsupported**, or **Not supported by this Folync server**. The market-data routes (history, candles, benchmarks, FX) are checked every minute. **Income**, **Trades** and **Activity** turn those pages' Folync data off and on; they are on by default and ask Folync nothing when changed. A page switched off says so the next time it is opened, and asks Folync again once switched back on; its sidebar entry stays as it is. A checkbox that is off cannot be turned on while Folync does not offer that data; one that is on can always be turned off. With VoiceOver, Stockbar speaks the result of each Folync action and of **Refresh Now**, and announces a connection problem once when it starts.

**Market-data keys** holds the FMP and Twelve Data API keys, one row each with the last test's result (**Verified**, **Verification failed** or **Not verified**, or **Not set** when no key is entered) beside **Save & Test**. **Fetch order** lists the providers in the order Stockbar tries them; **Edit Order** changes it.

## Refreshing and data freshness

- Prices refresh at the **Main Refresh Interval** (Settings → Refresh; default 5 minutes). A price younger than about 90% of the interval is reused.
- A symbol that fails is retried with increasing delays (1, 2, 5, then 10 minutes). After five consecutive failures it is paused for one hour; use **Retry Now** in its popover to resume sooner.
- **Data Health** summarises tracked rows, menu-bar visibility, currency and refresh settings.
- **Memory between refreshes.** Prices are fetched by a Python helper, a separate process that holds 70 MB or more. With **Settings → Advanced → Memory → Quit Python Helper When Idle** on, it quits about 90 seconds after its last request (it is checked every 20 seconds or so, so up to 115). Each refresh then starts it again, which takes about a third of a second of processor time and delays that refresh's first price by about as long. Turned off, the helper stays running for 15 minutes after its last request, so while markets are open it never quits at an interval shorter than 15 minutes. While markets are open, refreshing every minute keeps the helper running either way. While the London and US markets are closed their prices are fetched only every 30 minutes, so a helper with nothing else to fetch quits in between whether the setting is on or off. The setting is on unless you turn it off.
- **Rolling digits.** Figures in the main window and the popovers can roll to a new value when they change. macOS keeps the digits it draws for the rolling in memory: 6 to 10 MB when measured, each time after the main window's figures had rolled in as the window opened. **Settings → Advanced → Memory → Roll Digits When Figures Change** turns the rolling off, and figures then change without it. Memory already used may not be given back until Stockbar is restarted: it was still held 30 minutes later when measured. The setting is on unless you turn it off.

## Updates

Stockbar looks for a new version about once a day. When there is one it shows the version and its release notes; choose **Install Update** and Stockbar downloads it, checks it, installs it and reopens.

**Settings → General → Updates** shows the version you are running and has:

- **Update Channel** — **Stable** offers released versions only. **Testing** also offers every change as it lands, before it is released; these builds may be rough. **Experimental** offers builds of the `experimental` branch, which is used only for major changes or temporary testing, so it can be quiet for long periods and things may break; a released version or a testing build reaches it once the experimental work includes it. With automatic checks on, changing the channel checks again straight away.
- **Check Automatically** — turn off to check only when you ask.
- **Check Now** — the same as **Check for Updates…** in the **Stockbar** menu.

Things to know:

- **Keychain prompt after an update.** macOS asks once for access to your saved credentials (Trading 212, Folync, FMP and Twelve Data are kept in one Keychain item, "Stockbar credentials"). Choose **Always Allow**. The first update to a version that keeps them in one item asks once more for each credential saved by the version before, to move it across. Stockbar is built without an Apple developer account, so each build has a new signature and macOS does not carry the answer over.
- **Changing channel.** Stockbar never moves to an older build. After switching back to Stable you keep the testing or experimental build you have until a newer version is released. After switching from Experimental to Testing you keep it until there is a testing build newer than the one it was built on.
- **Where updates come from.** They are built by GitHub from Stockbar's source and downloaded from its GitHub releases. Stockbar checks each one against a signing key built into the app and refuses a download or an update list that does not match.
- **Development builds.** A build made from source in Xcode shows only its version here; updates are off.

## Backups, Data Health and Diagnostics

- **Backups** — Stockbar makes an automatic backup once a day. The Backups screen (and Settings → Advanced → Backups) shows the last backup and offers **Back Up Now**, **Restore from Backup…** and **View Backups**, plus how long to keep them. Restoring asks for confirmation. Keychain credentials are not included in backups.
- **Export & Import** — Settings → Advanced → Export & Import saves Stockbar to one password-protected `.stockbarexport` file, for example to move to another Mac. **Settings & Keys** holds your preferences plus the FMP, Twelve Data, Trading 212 and Folync keys. **Everything** adds your portfolio database; its estimated size is shown first. The file contains your API keys, so keep it and its password safe. **Import…** shows what the file contains and asks before replacing anything. Keys not in the file stay as they are, and Stockbar backs up your portfolio before replacing it, then relaunches. The Python environment and its interpreter path, window positions and caches are not exported.
- **Data Health** — price and exchange-rate freshness, portfolio source, tracked symbols, menu-bar visibility and preferred currency.
- **Diagnostics** — view, refresh and clear the log. The log file is at `~/Library/Logs/com.stockbar/stockbar.log`.

For recovery from outside the app, see [Scripts/README.md](../Scripts/README.md).

## Troubleshooting

**Prices are not updating.** Check your connection, then open the symbol's popover: if updates are paused, click **Retry Now**. Confirm the symbol on [finance.yahoo.com](https://finance.yahoo.com) (UK listings need `.L`). Make sure the Python packages are installed for the configured interpreter.

**A value shows "—".** The price or history is not available yet, the symbol is invalid, or the provider is temporarily unavailable. Missing values are shown as "—" rather than as a price.

**Risk or correlation says there is not enough data.** These need stored history; leave Stockbar running and data accumulates.

**Exchange rates look stale.** Rates from exchangerate-api.com are fetched at launch and then about once an hour (with Folync's **Exchange rates** switch on, they come from Folync and are checked every minute); Settings → General → Exchange Rates shows when they were last obtained. If an update fails, Stockbar keeps using the last rates it obtained. Only if it has never obtained any, for example on a new Mac that has not been online, does it use rough built-in rates; Holdings then says that converted values are approximate. A currency with no rate at all is shown as unavailable rather than guessed.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘O | Open Stockbar |
| ⌘, | Settings |
| ⌘R | Refresh prices (main window) |
| ⌘1 – ⌘9 | Show a page of the main window, top to bottom in the sidebar: Overview, Holdings, Activity, Alerts, Charts, Income, Calendar, Trades, Risk. Allocation, Data Health, Backups and Diagnostics have no number since Activity, Income, Calendar and Trades were added; choose them in the sidebar or the View menu |
| ⌃⌘S | Hide or show the sidebar |
| ⌘W / ⌘M | Close / minimise window |
| ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z | Standard editing in text fields |
| ⌘H | Hide Stockbar |
| ⌘Q | Quit |

The **Help** menu opens Data Health and Diagnostics and shows the log files in Finder.

## Privacy

Portfolio data is stored locally on your Mac (Application Support and Core Data). Market-data requests send ticker symbols to the configured providers. With a Folync portfolio, Calendar sends the holdings' ticker symbols to Yahoo for earnings dates, never amounts or units; Income and Next up ask Yahoo nothing. Broker and Folync credentials stay in your Keychain and are never written to logs. Update checks fetch a file from GitHub and send nothing about you or your Mac beyond what any web request shows (your IP address and the Stockbar version).
