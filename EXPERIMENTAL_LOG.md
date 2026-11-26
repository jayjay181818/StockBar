# Stockbar experimental log

The record of the optimisation work on the `experimental` branch: the baseline,
what each pull request changed and measured, and what was tried and dropped.
It changes only through pull requests into `experimental`.

To resume this work, read this file and the open pull requests into
`experimental` before anything else. The rules of the branch are in
[How this branch works](#how-this-branch-works).

## Where things stand

`experimental` has been promoted to `testing` three times, each time at
the owner's word. On 2026-11-13 pull requests 84 to 98 went to `testing` as
merge commit `2256b6c`, published as testing build 370.16: see
[Promotion to `testing`](#promotion-to-testing-2026-11-13). On 2026-11-17
pull requests 101 to 112 followed as merge commit `78c886b`, published as
testing build 370.29: see
[Second promotion to `testing`](#second-promotion-to-testing-2026-11-17).
On 2026-11-26 the redesign, pull requests 133 to 160, followed as merge
commit `9cb4276`, published as testing build 382.31: see
[Third promotion to `testing`](#third-promotion-to-testing-2026-11-26).
`main` has none of it, and no stable release has been made from it. The
owner considers the overhaul finished: from here `experimental` is kept for
major overhauls only.

Seven optimisations are merged, and they have been measured together
against the baseline twice: at [Milestone 1](#milestone-1-2026-11-12), and
on the promoted commit, which is the table below. The candidates that
remain are small or would change what the app does, so no further
optimisation is planned. Since the first milestone the owner has asked for
three things, none an optimisation of its own: an update channel that
follows `experimental` (pull request 97, merged), a switch for the Python
helper's early exit (pull request 86, merged) and a switch for the rolling
digits (pull request 98, merged).

- Release builds no longer carry test-coverage counters (pull request 85).
  The executable is 6.7 MB smaller and none of the fifteen measured rows
  moved.
- Stored portfolio history is read in batches (pull request 87). The peak
  memory of launch and history load is 16.4 MB lower: 267.4 MB against 283.8
  MB, measured in turns.
- Stored history is read at launch away from the main thread (pull request
  89). History is loaded 0.43 s sooner after launch, 0.60 s against 1.03 s,
  and the launch uses a quarter less CPU, 1.67 s against 2.23 s, measured in
  turns with the screen locked.
- Each portfolio snapshot's positions are kept in a sorted array instead of a
  dictionary (pull request 90). The memory the app holds allocated at idle is
  10.7 MB lower, 52.2 MB against 62.9 MB, and idle memory is 14.2 MB lower,
  95.8 MB against 110.0 MB, measured in turns.
- The chart of the portfolio's value reads stored history without each
  snapshot's positions (pull request 92). Its read of a week of history
  takes 2 ms against 24 ms, each time the chart reloads. None of the fifteen
  standard rows moved.
- The price history held in memory is kept in arrays sized to their points
  (pull request 93). Those arrays hold 5.25 MB against 8.69 MB, 3.44 MB
  less, in every launch.
- The popover charts no longer draw their line doubling back to the left
  either side of a gap in time, such as the night between two trading days
  (pull request 95). A bug fix, not an optimisation: the benchmark does not
  run its code, and no row moved in both of the two runs made for it.
- The app offers an Experimental update channel that follows this branch
  (pull request 97). Every push to `experimental` is now built, signed and
  published as a prerelease, so every merge here distributes a build. The
  merge itself published the first, 370.0.12.
- The idle Python helper quits after 90 seconds, with **Settings →
  Advanced → Memory → Quit Python Helper When Idle** (pull request 86). The
  switch is on unless turned off since pull request 102, at the owner's
  word; turned off, the helper is kept for 15 minutes as before. What it
  saves on real data is expected, not measured.
- The rolling digits of the figures can be turned off, with **Settings →
  Advanced → Memory → Roll Digits When Figures Change** (pull request 98).
  On, which is the default, nothing changes. Off, the system's cache of
  drawn digits held 0.4 MB against 9.4 to 9.9 MB with it on, in two
  launches each way. The standard benchmark was not run for this pull
  request, at the owner's instruction.
- `script/package_release.sh` refuses to package an app built with
  test-coverage counters (pull request 94, merged on the owner's word). It
  guards against the fault that pull request 85 removed coming back. The
  app is not changed.

Waiting for a decision:

- Whether the market data fetch should leave Python. The
  [Rust evaluation](#rust-evaluation-2026-11-12) sets out the options; no
  component was moved to Rust.

Decided on 2026-11-13:

- The helper's switch is on unless turned off (pull request 102). The
  owner chose it, knowing that on trades memory for CPU.
- "The rest of core" is the code the benchmark never runs, because it keeps
  live providers off: the price refresh and its network path, the Core
  Data writes made while prices are recorded, and the menu bar's updates.
  It starts with a read-only review whose findings go to the owner, and a
  refresh on made-up data added to the benchmark, so that changes there can
  be measured. Nothing in it is changed before the owner has seen the
  findings.
- The review's findings went to the owner, who chose for each what happens
  next. They are listed under
  [Review of the refresh path](#review-of-the-refresh-path-2026-11-13).
  Four are to be fixed, two to be looked into and reported before anything
  changes, and three left as they are. The first fix is pull request 104.
- Findings 6 and 7 were looked into and reported, with a larger finding
  of the same profile: the main window redraws once per symbol in every
  refresh, and goes on doing so after it is closed. The owner chose to
  apply each refresh's quotes together (pull request 106), to fix finding
  6 (pull request 107), and to leave finding 7. See
  [Findings 6 and 7 looked into](#findings-6-and-7-looked-into-2026-11-13).
- Pull request 106 halved the CPU and CPU energy of the refresh passes and
  raised their CPU wake-ups by 32%. Asked the same day, with the figures
  and a check that ties the wake-ups to the rolling digits, the owner
  chose to merge it.
- The eight Dependabot alerts for `urllib3` and `requests` were dismissed
  as inaccurate. `main` has pinned the fixed versions since 2026-11-05, but
  GitHub's dependency graph still holds `requirements.txt` as it was
  before. A small change to the file (pull request 103) goes to
  `experimental`, so that GitHub reads it again when it reaches `main`.

Decided on 2026-11-16: the two separate comparisons of pull requests 109
and 110 that a rule fixed before their full comparison called for were
dropped at the owner's word ("Lets drop them"). See
[pull request 109's entry](#109-release-the-portfolio-popovers-content-when-it-closes).

Decided on 2026-11-17: the overhaul is finished. The owner asked for
`experimental` to be promoted to `testing` again once the tests pass on it,
after this log is brought up to date, and for a stable release and `main`
to follow, each on their own word. They had run the experimental builds for
several days on a second Mac without a problem. From then on `experimental`
is for major overhauls of the app only, and ordinary changes go to
`testing` through pull requests as before the transition.

Done on 2026-11-13: `experimental` is promoted to `testing`. The owner
asked for it without the two trading days of use that the recommendation
at the end of [Milestone 1](#milestone-1-2026-11-12) suggested first. What
that section says the measurements do not cover still holds, now for the
testing build.

Decided on 2026-11-12 and done in pull request 98: the rolling digits of
the figures, which cost 6 to 10 MB of cached glyphs after a launch like the
benchmark's, have a switch of their own (plan item 14).

This comparison is re-measured, baseline commit against the head of
`experimental` in turns on the same day, at each milestone. Figures from
different days are not set side by side, because the machine's state drifts.

It was last measured on 2026-11-13, after the promotion, against `2256b6c`:
the commit the promotion put on `testing`, whose files are those of
`experimental` at `3cf549b`. Six launches a side in turns. These are the
rows that moved, the same six as at Milestone 1. The full table is under
[Promotion to `testing`](#promotion-to-testing-2026-11-13). The soak runs,
what the idle memory consists of and what is left are under
[Milestone 1](#milestone-1-2026-11-12).

| Metric | Baseline `47c1bda` | Promoted commit `2256b6c` | Change |
| --- | --- | --- | --- |
| Idle memory (physical footprint) | 119.9 MB | 95.8 MB | -24.2 MB, -20.1% |
| Idle memory the app holds allocated | 63.8 MB | 54.5 MB | -9.3 MB, -14.6% |
| Peak memory, launch and history load | 285.1 MB | 244.9 MB | -40.1 MB, -14.1% |
| Launch to history loaded | 1.20 s | 0.63 s | -0.57 s, -47.3% |
| CPU from launch to the idle window | 2.64 s | 1.88 s | -0.76 s, -28.8% |
| CPU energy from launch to the idle window | 7.85 J | 6.07 J | -1.78 J, -22.6% |

Idle CPU, wake-ups, idle CPU power, disk writes, launch to first window and
the three Python helper rows did not change measurably.

### Breaks in the measuring environment

Figures from either side of a break are not compared with each other.

- 2026-11-12, macOS 27.2 to 27.2.1. The Mac installed the update and
  restarted at 08:58 UTC, after the baseline and before pull request 85.
  `experimental` at `4f475ea`, whose app sources are the baseline's, was
  measured again after the update: it is the "before" column of pull request
  85. With the same app, launch to first window was 0.99 s against 1.38 s the
  night before and launch to history loaded 1.64 s against 2.34 s. Idle
  memory, allocated heap and peak memory were 2 to 3 percent higher and idle
  CPU 14 percent lower. A figure is therefore read against the "before"
  column measured beside it, never against the baseline table.
- 2026-11-12, from some time between 11:09 and 11:23 UTC until some time
  between 12:13 and 12:33 UTC: the Mac's screen was locked and its display
  mostly asleep, because its owner was away. The comparisons of pull requests
  85 to 87 ran unlocked with the display awake; pull request 89's ran locked;
  pull request 90's ran unlocked again, with the display awake for all twelve
  launches. Both sides of a comparison are still measured under the same
  conditions, in turns. Locked, the build that showed its first window in
  0.58 s in pull request 87's comparison shows it in 0.42 s, draws 1.4 mW of
  idle CPU power against 4.5 mW, and uses 0.16 s/min of idle CPU against
  0.08. A figure from a locked comparison is therefore not set beside one
  from an unlocked comparison.

### Milestones

| Milestone | State |
| --- | --- |
| `experimental` created, earlier work moved onto it | Done 2026-11-11 |
| Benchmark procedure and baseline in the repository | Done 2026-11-12, pull request 84 |
| Carried-over changes re-measured and merged one by one | Done 2026-11-12, pull requests 85 to 93. Pull request 86 became a switch that is off by default, on by default since pull request 102; pull request 94 waited for a decision and was merged on the owner's word on 2026-11-13 |
| Stage 3 changes | Done 2026-11-12. Plan items 8, 9, 11 and 12 were measured and none gave a change worth making; pull request 88 records the Rust evaluation |
| First checkpoint tag and soak run against the baseline | Done 2026-11-12: [Milestone 1](#milestone-1-2026-11-12), tag `experimental-checkpoint-2026-11-12-milestone-1` |
| Recommendation to promote to `testing` | Made 2026-11-12, at the end of [Milestone 1](#milestone-1-2026-11-12). The owner asked for the promotion on 2026-11-13 |
| Promotion to `testing` | Done 2026-11-13: pull request 100, merge commit `2256b6c` on `testing`, testing build 370.16. See [Promotion to `testing`](#promotion-to-testing-2026-11-13) |
| A look at "the rest of core" | Asked for by the owner on 2026-11-13, to follow the promotion, and settled the same day: the refresh path the benchmark never runs. The read-only review was done the same day and the owner chose what to do with each finding; see [Review of the refresh path](#review-of-the-refresh-path-2026-11-13). Done in pull requests 104 to 110 |
| Full comparison of pull requests 109 and 110 | Done 2026-11-16, six launches a side on the merged commit: no row moved firmly. See [pull request 109's entry](#109-release-the-portfolio-popovers-content-when-it-closes) |
| Second promotion to `testing` | Done 2026-11-17: pull request 113, merge commit `78c886b` on `testing`, testing build 370.29. See [Second promotion to `testing`](#second-promotion-to-testing-2026-11-17) |
| Stable release and `main` | Asked for by the owner on 2026-11-17, after they had used testing build 370.29 and experimental build 370.29.2 and checked the portfolio popover by hand: version 3.8.0, released from `testing` by its own pull request and tag, with `main` brought up to date afterwards. Pull request 111, the weekly Python package update, is not in it: the recommendation was for it to follow the release, so that the release installs the packages that were tested |

### Planned next, in order

1. Done in pull request 85: release builds without test-coverage counters.
   The branch also carried a check in `script/package_release.sh` that refuses
   an instrumented binary. That is a change to the release packaging step, so
   it came off the branch as pull request 94, which waited for a decision
   and was merged on the owner's word on 2026-11-13.
2. Done in pull request 86, as a switch that is off by default: the idle
   Python helper quits after 90 seconds. As a fixed change it traded memory
   for CPU and waited for a decision; the owner asked for a switch. Its
   effect shows only on real data. The owner asked on 2026-11-13 for it to
   be on by default, which pull request 102 does.
3. Done in pull request 87: portfolio history read in batches.
4. Done in pull request 89: stored history read at launch away from the main
   actor.
5. Done in pull request 92: the chart of the portfolio's value reads stored
   history without each snapshot's positions.
6. Done in pull request 93: price history arrays sized to fit.
7. Done in pull request 90: compact storage for the positions kept with every
   portfolio snapshot, which were the largest single block of the idle heap.
8. Measured, not pursued: the Python helper's start-up cost. The helper
   compiles its own three scripts at every start, because the app sets
   `PYTHONDONTWRITEBYTECODE`. Compiling them takes 8.2 ms in all
   (`get_stock_data.py` 7.5 ms, range 6.3 to 58.8 over 20 compiles; the other
   two 0.3 and 0.4 ms), of a start that takes about 330 ms. Shipping
   bytecode would save about 2 percent of the helper's start. Retiring the
   helper straight after a refresh is the trade of pull request 86 taken
   further, and is not planned.
9. Measured, nothing to change: the graphics memory of the first window (the
   result is at the end of this item). AppKit's Writing Tools check during
   launch was not looked into. Also why one and the same build idles near 105 MB after
   some launches and near 130 MB after others (see pull request 87). Across
   the 36 launches of the comparisons of pull requests 85 to 87, ten idled
   above 120 MB and 26 below, and the heap the app holds allocated was the
   same at both levels (medians of 61.0 MB and 61.8 MB). The extra 22 MB or
   so is therefore memory outside the allocated heap. The memory breakdowns
   saved with those launches show what it is: the small-allocation zone held
   101.0 MB at the high level and 79.5 MB at the low one, 21.5 MB apart, and
   apart from 1.6 MB of large allocations no other kind of memory differed by
   as much as 0.1 MB. So it is memory the launch freed that the allocator has
   not handed back, and the allocator does not hand it back on request (see
   "Tried and rejected"). In pull request 90's comparison that zone held 80.5
   MB against 62.9 MB allocated before, and 67.0 MB against 52.2 MB after.
   What is left to work on is therefore what the launch allocates at its
   peak: 250 MB, for 52 MB kept.

   The peak was then looked at directly. A launch of `c4f4cff` was captured
   at the moment its footprint passed 150 MB (it stood at 157.6 MB): 100.6
   MB of that was graphics memory the process owns for the first window,
   which is 48 KB once the app is idle, and 50.8 MB was the small-allocation
   zone, against 44.9 MB at idle. The heap held the same classes in nearly
   the same amounts as at idle. So the benchmark's launch peak is the first
   window being drawn, not the history load, and in normal use no window
   opens at launch. Pausing the app to capture it changed that launch: it
   peaked at 192.5 MB where undisturbed launches of the same build peak at
   242 to 247 MB. The capture therefore shows what the peak is made of, not
   its size.
10. Done in pull request 88: Rust evaluated, no migration recommended. See
    the [Rust evaluation](#rust-evaluation-2026-11-12).
11. Measured, not pursued. Seen while reading for pull request 93: after
    every recorded snapshot `cleanupOldData` thins every symbol's price
    series again on the main actor, which sorts and copies each one and
    works out the calendar day of every older point, and then keeps the
    result only if its length changed. The benchmark records no prices, so
    this was timed on a copy of the code compiled with `-O`: one pass over a
    store shaped like the benchmark's (22 symbols, 70,004 points) takes 32.6
    ms (30.0 to 40.6 over 200 passes). 27.3 ms of that is working out the
    calendar day of the 22,000 older points and 2.4 ms is sorting series
    that are already in order. At the default five-minute interval that is
    0.0065 s of CPU a minute while prices are being recorded, against 0.09
    s/min for the idle app. Doing only the work that can change anything
    means remembering how far each series has been thinned, and keeping
    that true at every place that replaces a series and in every time zone
    the Mac moves through. That is new state to get wrong, for about 2 s of
    CPU in a trading day.
12. Measured, nothing changed: why one and the same build holds about 6 MB
    more allocated after some launches than after others, and whether the
    main window's chart is the cause. It is not the chart. It is the
    system's cache of drawn glyphs, filled when the main window's figures
    roll in. See "What the idle memory is made of" under
    [Milestone 1](#milestone-1-2026-11-12).
13. Done in pull request 97, merged on the owner's word on 2026-11-12: an
    update channel in the app that follows `experimental`, asked for by the
    owner the same day. It is a feature, not an optimisation. The release
    workflow now builds and publishes each push to `experimental`, starting
    with the merge itself. The builds go in an update feed of
    their own: the copy of `Scripts/release_feed.py` on `testing` and
    `main` refuses to rewrite a feed that holds a channel it does not know,
    so a shared feed would stop testing builds and releases from being
    published.
14. Done in pull request 98, asked for by the owner on 2026-11-12: a switch
    beside the helper's, in Settings → Advanced → Memory, that turns off
    the rolling digits and with them the cached glyphs: 0.4 MB held with
    it off against 9.4 to 9.9 MB with it on. On unless turned off. The
    standard benchmark was not run, at the owner's instruction.

No further optimisation of what the benchmark runs is planned. Under way
is "the rest of core": the owner's choices from the
[review of the refresh path](#review-of-the-refresh-path-2026-11-13), one
pull request each. Done: finding 1 (pull request 104), the refresh
workload (pull request 105), the redraw per symbol (pull request 106,
which halves the refresh passes' CPU and raises their wake-ups, a
trade-off the owner accepted), finding 6 (pull request 107), finding 5
(pull request 108), finding 9 (pull request 109) and finding 8 (pull
request 110), which completes the findings the owner chose to fix. The
last two shared a shortened comparison when they were merged, and a full
one on the merged commit the same day, in which no row moved firmly. Open
for the owner are whether the fetch should leave Python, the cached quote
shown as just updated, the price alerts' repeated rewrite, and whether the
per-symbol popovers should release their content as pull request 109 does
for the portfolio's. None of them holds the promotion. `experimental` was
promoted to `testing` on 2026-11-13, and the owner asked on 2026-11-17 for
it to be promoted again. What could still be done, and what
each would cost, is listed at the end of
[Milestone 1](#milestone-1-2026-11-12).

From 2026-11-19, at the owner's word, `experimental` is in use again for a
major change: the Glass redesign and the new Folync pages. Pull request 133
brought it up to `testing` first, with merge commit `01d4768`. The owner
said the benchmark for this work can wait until after 02:30 on 2026-11-20
or later. Pull request 134's comparison was run that morning, twice, with
another project's `xcodebuild` present on the same Mac during every
measured launch. After the repeat no row shows a measurable change, and
both tables are in its record. No launch was measured on a quiet Mac, and
the rule written before the first launch left the merge to the owner in
that case. The owner then said "go on", which is the word the rule asked
for, and it was merged on 2026-11-20 as `5fa923b`.

The same day the owner parked the benchmarks: no comparison is run until
the other project's work on this Mac has been idle for more than 20
minutes. Pull request 135, the first of the redesign's data work,
therefore has no table yet. Asked the same day, the owner chose to merge
the redesign's pull requests on their local checks and review with the
benchmark owed. One comparison for each phase is run in the first quiet
window, and until then each record says that its benchmark is owed. The
rule is set out under [How this branch works](#how-this-branch-works).
Pull request 135 was merged on those terms on 2026-11-20 as `e04e21b`.
Pull request 136, the Yahoo lookup the Calendar needs, followed it the
same day as `16f1a3d`. Pull request 137 is the first that changes what the
app looks like: on 2026-11-20 the owner chose the floating sidebar and said
to build the Glass look and judge it on experimental builds. It was merged
the same day as `fe59b8d`. The shell, the popover and the Overview were then
built at the same time, each as its own pull request; the popover's, 138,
was ready first and was merged as `564056b`. The Overview's, 139, was
brought up to date with it and followed as `c9453fd`. The shell's, 140, is
the last of Phase A, and was merged as `92145d7`. With it the phase's
comparison is owed: from `5fa923b`, the last commit measured, to the head,
in the first quiet window. A first try the same afternoon measured
nothing: the other project's builds ran during the wait for twenty quiet
minutes, and the Mac then went onto battery power. The owner chose to have
it run that night at 02:30 UTC, with the Mac on mains power and left
alone.

Phase B's pages followed the same day, built at the same time, each as its
own pull request: Activity (141, merged as `474d187`), Trades (142,
`a60edd0`) and Income (143, `9292744`). A local stand-in
server with a made-up portfolio now serves the three ledger routes, so
each page can be looked at in the acceptance copy. A second batch, built
the same way, gave Allocation a donut and its correlations as a grid
(144, `c34be9e`), put switches for the three new pages in Settings (145,
`80dfcbc`), gave Holdings a Weight column (146, `9d87d22`) and said each
of Risk's figures once, with a chart of the falls (147, `995293c`). Pull
request 148 (`3aff316`) let the acceptance copy change the settings it
was started with, which showed for the first time that the Holdings
editing table did not fit at the minimum window size. Pull request 149
(`241aeb7`) tidied Charts and Data Health, and pull request 150
(`2d5d992`) made the editing table fit. All were merged on 2026-11-20
with their benchmark owed; the last of them published experimental build
382.3.19.

The comparison owed for all of it was run that evening, at the owner's
request, instead of at 02:30 UTC: from `5fa923b` to `2d5d992`, which
covers pull requests 135 to 150, twice, from 22:10 to 22:43 UTC and from
23:03 to 23:35 UTC, each after twenty quiet minutes on mains power. Both
runs were kept under all three set-aside rules. Three rows rose in both:
idle memory by 21 to 22 MB, peak memory at launch by 20 to 23 MB, and
CPU from launch to the idle window by 0.09 to 0.11 s. The memory the app
holds allocated did not hold its rise in the repeat, so the extra memory
is most likely what the system holds for the app, such as what it draws
the window with, rather than the app's own objects. Pull request 140, the
Glass shell, was named the likeliest cause; measured on its own that
night, it is not: the rise is already there before it. Both tables are in
[pull request 151's entry](#151-record-the-redesign-benchmark-and-bring-the-log-up-to-date),
which was merged on 2026-11-21 as `381fad1` (build 382.3.20).

Pull request 140's own comparison, `c9453fd` against `92145d7`, was run at
01:01 UTC on 2026-11-21. Idle memory did not move (114.9 MB before, 116.4
MB after), and peak memory at launch rose by 19.5 MB. In every launch the
system's drawing memory for the app (the `CoreAnimation` region of the
footprint) is 3.2 MB at `5fa923b` and 22 MB from pull request 139 onwards,
so the idle rise is in pull requests 135 to 139; 135 and 136 change no
view, which leaves 137 (Glass surfaces), 138 (the popover) and 139 (the
Overview). They are measured one at a time next. The table is in
[pull request 153's entry](#153-read-yahoos-chart-details-with-the-yfinance-the-app-ships).

On 2026-11-25 the owner allowed one supervised live run of the Yahoo
events lookup (pull request 136) before Calendar, a local Income estimate
and a Funds group are built on it. It found that the lookup had never
answered: with the yfinance the app ships, every symbol was thrown away as
having no data. Pull request 153 fixes that and records what Yahoo gives;
it was merged the same day as `6e7184d` (build 382.3.21).

The owner also chose a Cash row for Allocation, so that its shares are of
the same total as Holdings' weights. Pull request 154 adds it. Two independent
reviews (GPT-6.2 Astra and Gemini 4 Neon) then found it could still
disagree with Holdings or show another account's cash, and pull request
155 fixes that: one source decides holdings, total and cash, and the Cash
row appears only when the figures add up to the source's total.

The rise in idle memory was traced the same day, by one launch of each of
pull requests 136 to 138 while another project's builds kept the Mac from
a timed comparison: the system's drawing memory for the app is 3.2 MB
after 136, 19 MB after 137 (the Glass surfaces), 19 MB after 138 and 22
MB from 139. The results are in
`build/bench/results/coreanimation-check-20261125-115919`.

Pull request 155 was merged as `f925fae` (build 382.3.23). Pull request
156 then valued a Trading 212 account that holds only cash, which no
ordinary sync had done, and, after two more independent reviews, made
Trading 212's figures belong only to the account in use and never to a
Folync portfolio. It was merged as `1dcde6f` (build 382.3.24).

Pull request 157 then removed the idle memory the redesign added: the
faint top highlight on dark cards, stroked with a gradient, cost about 18
MB of drawing memory, and drawing it under a gradient mask instead keeps
the look and brings that memory back to 3.6 MB. It was merged as
`45cd139` (build 382.3.25). The timed comparison for pull requests 152
to 157 was run that evening, twice: idle memory fell from about 118 MB to
about 100 MB, peak memory at launch by 16 to 22 MB, and nothing else
changed measurably. The tables are in pull request 158's entry.

Pull request 158 gave a local or Trading 212 portfolio an Income page, as
an estimate labelled as one: Yahoo's record of each holding's payments
over the last year, at today's units, and the same a year on.
It was merged as `0c77a54` (build 382.3.26).

On 2026-11-26 the owner asked for the redesign to go to `testing`. Pull requests 133 to 160 were promoted as
merge commit `9cb4276` and published as testing build 382.31; CI's first
run on the promotion found one test holding the system's wording, fixed by
pull request 160. Pull request 161 brought `testing` back, merged as `8fb23f8`.

Pull request 162 gives the six Settings tabs one left edge and one width,
arranges Connections as in the mock-up, checks Alerts with made-up alerts
(an acceptance-only fixture that never stores, checks or notifies) and
tidies the Diagnostics log. It was merged as `9a2c046` (build 382.31.3).
Pull request 163 gives the Sortino ratio a reading again, at the owner's
request (merged as `be6ff84`, build 382.31.4). Pull request 164 adds the
Calendar and "Next up". What remains of the redesign before a stable
release: Reminders and the release documents. Pull request 164 was merged
as `06689ee` (build 382.31.5); pull request 165 lets Activity's kind
switches combine, with Interest on its own (merged as `6539947`). Pull
request 166 rebuilds every Settings tab as Glass cards at the page's full
width.

## Review of the refresh path, 2026-11-13

A read-only review of the code the benchmark never runs: the price refresh
and its network path, the Core Data writes made while prices are recorded,
and the menu bar's updates. An Opus subagent that had not seen the code did
the reading. Findings 1 and 4 and the first possible fault were checked
again in the code before they went to the owner. The costs are counted from
the code, not measured.

Possible faults, with the owner:

- A quote served from the Python helper's quote cache is stamped by the app
  as updated at the time it arrives. "Refresh now" within about four and a
  half minutes of the last fetch can show an old price as fresh, and at a
  one-minute refresh with more than about six symbols the later symbols
  are fetched only every other pass while the repeated price is saved as a
  new sample.
- The FTSE 100 index, `^FTSE`, has no London suffix, so the app gives it
  New York's market hours. It is polled at full rate from 09:00 to 01:00
  London time, mostly while London is shut, and only every 30 minutes from
  07:00 to 09:00, while London is open.

Where the refresh does more work than it needs, ranked by expected benefit,
with the owner's decision on each:

| # | Finding | Owner's decision |
| --- | --- | --- |
| 1 | The Python helper rewrites its whole quote cache file, and forces it to disk twice, for every symbol of every refresh. The cache also almost never answers, because its entries live for 0.9 of the refresh interval | Fix. Pull request 104 |
| 2 | Two requests to the provider per symbol per refresh: the helper downloads five days of daily prices every time, to get the previous close | Leave as it is |
| 3 | Symbols whose market is closed are still fetched every 30 minutes, all night and at weekends, and each fetch saves a portfolio snapshot that the weekly clean-up later deletes | Leave as it is |
| 4 | The two benchmark indices, the S&P 500 and the FTSE 100, are fetched at every refresh | Keep as it is, including the FTSE 100's hours |
| 5 | The history cache files are rewritten 36 to 48 times an hour while prices are recorded, whether or not anything changed | Fix. Pull request 108 |
| 6 | The menu bar rebuilds each symbol's merged price history about three times per refresh | Looked into: confirmed, about 66 ms of the main thread per refresh. Fixed in pull request 107 |
| 7 | Each refresh makes three separate Core Data transactions, and one of them rewrites every position's price row | Looked into: confirmed, under 10 ms per refresh. Leave as it is |
| 8 | Each portfolio snapshot taken during the session stores every position's price, which nothing reads | Fix. Pull request 110 |
| 9 | The portfolio popover keeps its content after it closes, and recalculates its summary at every refresh | Fix. Pull request 109 |

Also found, not yet put to the owner as an item of its own: price alerts
rewrite the whole saved list of last prices once for each symbol with an
alert, at every refresh, where once per refresh would do.

The review also recommended adding a refresh on made-up data to the
benchmark, so that findings 5 to 9 can be measured. That was part of what
the owner settled on 2026-11-13 for "the rest of core". It is pull request
105: `Scripts/perf/compare.sh --refresh`.

### Findings 6 and 7 looked into, 2026-11-13

Measured in the benchmark's isolated copy of the app, `experimental` at
`93198fc`, on the refresh workload of pull request 105: four passes 30 s
apart, eleven holdings and two indices, 69,982 stored prices in memory over
22 series, and the main window open, as in every benchmark launch. Nothing
was changed. Two tools, three runs:

- `sample` over the 122 s of the four passes, one sample every 1.33 ms of
  every thread. 3,234 samples found a thread at work rather than waiting,
  2,895 of them on the main thread.
- The same launch with Core Data's SQL log on
  (`-com.apple.CoreData.SQLDebug 1`), for what each pass writes.
- A trial copy, never committed, that wrote a line to standard error for
  each evaluation of the main window's overview page, each ticker item's
  update and the start and end of each pass. Three refresh launches in
  turn: window open, window closed by the copy 5 s before the first pass,
  window open again. CPU over the 120 s from `Scripts/perf/proc_usage`.

Where the work of a refresh goes, in busy samples over the four passes:

| Work | Busy samples | Share |
| --- | --- | --- |
| Main window: SwiftUI updates, the overview chart, Core Animation commits, a blurred shadow drawn on the CPU, AppKit layout | 2,738 | 85% |
| Menu bar ticker items | 229 | 7% |
| The refused history backfill that starts two minutes after launch; not part of the refresh | 99 | 3% |
| Recording the portfolio snapshot and thinning the stored prices | 74 | 2% |
| The refresh pass itself | 26 | 1% |
| Core Data, on its own threads | 17 | 0.5% |
| The rest | 51 | 1.5% |

The main window, a finding of its own. A pass applied each quote and then
waited on the cache coordinator and the log before the next. Each wait let
SwiftUI redraw what observes the holdings, so the overview page was
evaluated again after every symbol: 18 or 19 times a pass, about every 45
ms, in all three trial launches. A pass took 0.73 to 0.80 s from start to
end, most of it those redraws. The window keeps its content when it is
closed (`isReleasedWhenClosed` is off and the controller holds it), and
closing it saved nothing: 3.80 s/min of CPU over the refresh window with
it closed, against 3.60 and 3.59 with it open, and the same 18 or 19
evaluations a pass. The window is shown at every launch
(`AppDelegate.swift`), so in normal use it is open or closed after being
open, and either way it does this work. Inside each redraw, the chart's
colour is worked out twice for every one of its 732 points, each time
reading the chart model's published data again (156 busy samples).

Finding 6, confirmed. Each of the eleven ticker items updates three times a
pass: when its quote is applied, when the holdings list announces a change
just after the pass, and 250 ms after the stored prices change. Each update
asks for the symbol's last 24 hours, and that merges the symbol's whole
stored series with its live samples
(`InstrumentAliasHistoryLookup.combinedSnapshots`) to keep 71 to 85 points
of it. The cache in front of the merge, `AliasPriceSnapshotCache`, holds
7,200 points in all, against 69,982 in memory, and is emptied whenever a
price or a live sample is recorded, so during a refresh it does not
answer. The merge is 198 of the menu bar's 229 busy samples: about 66 ms
of the main thread a pass, growing with the stored history.

Finding 7, confirmed and cheap. Each pass makes three write transactions,
each after an empty one: the eleven holdings' saved price rows are
updated, 13 price samples are added, and one portfolio snapshot is added
with its 11 positions. Each also writes Core Data's change history, one row
for each object changed, 35 a pass, which nothing in the app reads except
the clean-up that deletes it, and posts a change notification. 17 busy
samples over the four passes, under 10 ms a pass. Pull request 105 measured
0.046 MB written over the four passes in four refresh launches of six.

The owner's decisions, the same day:

- The main window: apply each pass's quotes together before waiting on
  anything, so the window redraws once a pass rather than once a symbol.
  Pull request 106. Not chosen: working out the chart's colour once per
  redraw, and dropping the window's content when it is closed.
- Finding 6: read only the last day of the sorted history. Pull request
  107.
- Finding 7: leave as it is. Recorded under
  [Tried and rejected](#tried-and-rejected).

## Baseline

Untouched `experimental` at `47c1bda`, which has the same files as `testing`
and `main` had on 2026-11-11 (release 3.7.0). Measured on 2026-11-11 between
23:08 and 23:54 UTC on an Apple M3 Pro with 18 GB, macOS 27.2, on mains
power. The display was awake and unlocked for every launch.

```bash
bash Scripts/perf/compare.sh experimental dd30bb3 --label baseline --rounds 2 --runs 4
```

A Release build runs in the isolated acceptance mode on synthetic data (11
holdings, 7,000 portfolio snapshots of 15 positions, 69,982 prices), with live
providers off. Each launch is left for 75 seconds and then watched for 60.
There were eight launches a side, taken in turns. The other side is `dd30bb3`,
the commit that adds the benchmark, whose app sources are the same. Its column
is therefore a second sample of the same app, and the difference between the
two columns is the noise of the method.

| Metric | Baseline: median (range) of 8 launches | The same app again | Difference |
| --- | --- | --- | --- |
| Idle memory (physical footprint) | 103.5 (100.0 to 114.9) MB | 104.5 (99.5 to 127.1) MB | none measurable (p = 0.645) |
| Idle memory the app holds allocated | 60.7 (59.7 to 61.7) MB | 60.4 (54.9 to 61.9) MB | none measurable (p = 0.817) |
| Peak memory: launch, first window, history load | 275.1 (272.8 to 292.3) MB | 282.6 (271.9 to 292.9) MB | none measurable (p = 0.328) |
| Idle memory growth across the 60 s window | 0.0 (-6.9 to 0.0) MB | 0.0 (0.0 to 0.9) MB | none measurable (p = 0.533) |
| Idle CPU | 0.100 (0.091 to 0.107) s/min | 0.103 (0.084 to 0.161) s/min | none measurable (p = 0.776) |
| Idle CPU wake-ups | 26 (23 to 28) /min | 26 (24 to 43) /min | none measurable (p = 0.667) |
| Idle CPU power | 4.43 (4.24 to 5.36) mW | 4.64 (4.22 to 6.80) mW | none measurable (p = 0.663) |
| Idle disk writes | 0.000 MB/min in every launch | 0.000 MB/min in every launch | none |
| Launch to first window | 1.38 (1.02 to 1.57) s | 1.21 (0.95 to 1.47) s | -0.17 s at p = 0.050: noise, see below |
| Launch to history loaded | 2.34 (1.74 to 2.81) s | 2.19 (1.68 to 2.72) s | none measurable (p = 0.342) |
| CPU from launch to the idle window | 3.07 (2.69 to 3.49) s | 2.75 (2.39 to 3.32) s | none measurable (p = 0.065) |
| CPU energy from launch to the idle window | 8.37 (7.69 to 9.80) J | 7.97 (7.17 to 10.12) J | none measurable (p = 0.442) |
| Python helper start to ready, no network | 0.35 (0.29 to 0.84) s | 0.39 (0.33 to 0.68) s | none measurable (p = 0.553) |
| Python helper start, CPU | 0.34 (0.29 to 0.49) s | 0.38 (0.32 to 0.42) s | none measurable (p = 0.311) |
| Python helper memory once started | 71.2 (71.0 to 71.3) MB | 71.2 (71.0 to 71.4) MB | none measurable (p = 0.959) |

What this says about reading later tables:

- The same binary idles anywhere between 100 and 127 MB from launch to
  launch, because the allocator keeps or returns memory freed during the
  launch. The allocated figure is far steadier, so a memory change shows there
  first.
- Launch times move by about 0.3 s either way between launches.
- One row of the fifteen separated the two sides at p = 0.050 although the app
  was the same. With fifteen rows that is expected in about half of all
  comparisons, so the report calls a row "lower" or "higher" only below
  p = 0.01 and marks anything between 0.01 and 0.05 as "possibly", to be
  repeated before it counts. A pull request also names in advance the rows it
  is meant to move.

Where the memory is, from the heap listing of one baseline launch (59.7 MB
allocated): the position dictionaries of the 7,000 portfolio snapshots 17.1
MB, the price history arrays 8.7 MB, allocations without a type name 12.9 MB,
Swift type metadata 3.4 MB. (MB is 1,048,576 bytes throughout, as the tools
report it.) Of that launch's 103 MB idle footprint, 75 MB is the
malloc heap and about 13 MB is graphics and window memory. The peak, about
275 MB, is reached before the idle window starts; this tooling does not yet
say what it is made of (item 9 of the plan).

### Soak: 30 minutes idle

One launch of the same build watched for 30 minutes, from 23:55 on 2026-11-11
to 00:26 UTC. This is too slow for every pull request and is run at
milestones.

```bash
bash Scripts/perf/benchmark.sh --skip-build --commit-label 47c1bda --label baseline-soak --runs 1 --window 1800
```

| Metric | Over the 30 minutes |
| --- | --- |
| Idle memory (physical footprint) | 103.1 MB over the first five minutes, 104.9 MB over the last five; lowest 101.9, highest 105.0 |
| Memory the app holds allocated, at the end | 60.3 MB |
| Idle CPU | 0.032 s/min |
| Idle CPU wake-ups | 27.7 /min |
| Idle CPU power | 0.43 mW |
| Idle disk writes | 0.001 MB/min |

Memory rose by 1.8 MB over the half hour, in steps. Whether it levels off
over hours is not measured. Idle CPU and power over the half hour are well
below the 60 second figures in the table above, because that window starts 75
seconds after launch, while the app is still settling: compare a soak with a
soak and a table with a table.

### Tests on the baseline

Run on 2026-11-12 on the tooling branch, whose app sources and tests are
those of `47c1bda`:

- `bash script/develop.sh test`: 682 XCTest tests, 0 failures.
- `bash script/develop.sh python-tests`: 66 Python helper tests pass.
- `bash script/develop.sh checks` and `docs-check`: lint, entitlements,
  sendable, invariant and agent-document checks pass.
- `bash script/develop.sh build-release`: the Release configuration builds.

Nothing fails on the baseline, so the bar for every later pull request is no
failures at all.

### Not measured

| What | Why not | What would fill the gap |
| --- | --- | --- |
| Whole-system battery drain | `powermetrics` needs administrator rights. The CPU energy figures above are the kernel's estimate for the process alone: no display, graphics processor or network | `sudo powermetrics --samplers tasks,battery -i 10000 -n 60` while the app idles |
| Frame-level smoothness and click-to-response time | Needs Instruments or instrumentation inside the app. Time to first window and launch CPU are the nearest figures here | Instruments (Time Profiler, Hangs, SwiftUI) against the Release build |
| A quote refresh over the network | Depends on the provider and the network, and the isolated benchmark has live providers off. The helper's start to ready, without the network, is measured instead | `bash Scripts/measure_performance.sh` against the running app, read together with the refresh lines in its log |
| How long the Python helper stays alive between refreshes, and app plus helper memory | The isolated benchmark never starts the helper. Measuring it means quitting the installed app and running a test build on real data, which is not done unattended | `bash Scripts/measure_performance.sh --duration 720` against a build of the commit |
| Memory, CPU and energy while the app is being used (charts, settings, scrolling) | Nothing here drives the interface. "Active" in the tables is the launch, the first window and the history load | Use the app while `measure_performance.sh` runs |
| Operation over hours with real refreshes | The soak run is 30 minutes, idle, in isolation, at milestones only | `bash Scripts/measure_performance.sh --duration 7200` on the installed app |

## Milestone 1, 2026-11-12

Every change merged so far, measured together against the baseline. The
comparison ran with `experimental` at `c4f4cff` (pull requests 84 to 93).
The head when this was written, `c3c21ec`, adds pull request 95, whose code
the benchmark does not run; the soak and the tests below ran on `c3c21ec`.
The checkpoint tag `experimental-checkpoint-2026-11-12-milestone-1` is on
the commit that merged this section, whose app sources are those of
`c3c21ec`.

### Comparison with the baseline

```bash
bash Scripts/perf/compare.sh 47c1bda c4f4cff --label milestone-1
```

Six launches a side in turns, from 15:21 to 15:53 UTC, on macOS 27.2.1 and
mains power, all twelve launches with the screen unlocked and the display
awake. The load average was 6.9 at the start, after waiting 140 s for it to
fall below 8.

| Metric | Before: median (range) | After: median (range) | Change | Verdict |
| --- | --- | --- | --- | --- |
| Idle memory (physical footprint) | 121.5 (100.2 to 132.8) MB | 98.3 (96.2 to 101.6) MB | -23.2 MB, -19.1% | lower (p = 0.009) |
| Idle memory the app holds allocated | 60.4 (59.6 to 61.7) MB | 54.0 (50.3 to 56.2) MB | -6.4 MB, -10.5% | lower (p = 0.002) |
| Peak memory, launch and history load | 281.1 (275.6 to 298.5) MB | 244.4 (242.1 to 247.3) MB | -36.7 MB, -13.0% | lower (p = 0.002) |
| Idle memory growth across the window | 0.0 (-9.1 to 0.1) MB | 0.0 (-3.2 to 0.1) MB | +0.0 MB | no measurable change (p = 0.939) |
| Idle CPU | 0.091 (0.089 to 0.101) s/min | 0.087 (0.068 to 0.095) s/min | -0.004 s/min, -4.4% | no measurable change (p = 0.292) |
| Idle CPU wake-ups | 28 (23 to 35) /min | 27 (25 to 32) /min | -0 /min, -1.8% | no measurable change (p = 1.000) |
| Idle CPU power | 4.41 (4.24 to 5.34) mW | 4.42 (3.92 to 4.78) mW | +0.01 mW, +0.2% | no measurable change (p = 0.937) |
| Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
| Launch to first window | 0.97 (0.66 to 1.39) s | 0.61 (0.46 to 0.86) s | -0.35 s, -36.3% | possibly lower (p = 0.024) |
| Launch to history loaded | 1.88 (1.32 to 2.55) s | 0.72 (0.60 to 0.83) s | -1.15 s, -61.3% | lower (p = 0.002) |
| CPU from launch to the idle window | 2.46 (2.33 to 2.86) s | 2.07 (1.92 to 2.16) s | -0.39 s, -16.0% | lower (p = 0.002) |
| CPU energy from launch to the idle window | 7.76 (7.07 to 9.20) J | 6.37 (5.34 to 6.79) J | -1.39 J, -18.0% | lower (p = 0.002) |
| Python helper start to ready, no network | 0.39 (0.28 to 0.64) s | 0.34 (0.30 to 1.14) s | -0.05 s, -14.1% | no measurable change (p = 0.777) |
| Python helper start, CPU | 0.34 (0.28 to 0.40) s | 0.33 (0.30 to 0.54) s | -0.01 s, -4.4% | no measurable change (p = 0.965) |
| Python helper memory once started | 71.0 (70.9 to 71.2) MB | 71.0 (69.9 to 71.1) MB | +0.0 MB, +0.0% | no measurable change (p = 0.470) |

- Launch. History is loaded 1.15 s sooner, and the launch uses 16 percent
  less CPU and 18 percent less CPU energy. The first window came out
  "possibly lower", 0.61 s against 0.97 s. That was not repeated and does
  not count.
- Peak memory is 36.7 MB lower.
- Idle memory is 23.2 MB lower between the medians. Part of that is the
  baseline's two levels (plan item 9): its six launches here idled at
  100.2, 115.1, 116.7, 126.3, 128.1 and 132.8 MB. The six launches of
  `experimental` idled at 96.2 to 101.6 MB, so its highest is about where
  the baseline's lowest is.
- The memory the app holds allocated is 6.4 MB lower. Pull requests 90 and
  93 took out 10.7 MB and 3.44 MB in their own comparisons. The total here
  is smaller because the faster launch adds something back, which the next
  section explains.
- Idle CPU, wake-ups, idle CPU power and disk writes did not change
  measurably, and nothing merged was aimed at them. The Python helper is
  unchanged; pull request 86, which is about it, was open at the milestone
  and has since become a switch.

### What the idle memory is made of

One launch was run with the system recording where every allocation is
made (`MallocStackLogging=lite`), which lets `heap` name the allocations it
otherwise lists as untyped. The build was that of `4ba6ea8`, whose app
sources are those of `c3c21ec`, started the way the benchmark starts it and
read a minute after its history had loaded. It held 55.7 MB allocated.

| What | Allocated | Blocks |
| --- | --- | --- |
| Bitmaps of drawn glyphs, cached by CoreGraphics | 6.52 MB | 3,267 |
| Positions of the 7,000 portfolio snapshots | 5.98 MB | 7,000 |
| Price history arrays | 5.25 MB | 24 |
| What Swift Charts keeps for the main window's chart of 730 points (248 classes) | 5.42 MB | 4,907 |
| Swift type metadata | 4.34 MB | 255 |
| Objective-C method caches | 1.58 MB | 1,814 |
| Everything else: 5,022 classes, none above 1 MB | 26.6 MB | 226,889 |

The glyph bitmaps are the part earlier tables could not explain. In
comparisons since pull request 89, one and the same build held about 6 MB
more allocated after some launches than after others, all of it untyped;
pull request 93's entry notes a spread of 5.9 MB. Two guesses were tested.

It is not the chart. A trial build drew the main window's series as one
area plot and one line plot in place of a mark for every point, and three
launches of it were set against three of the build it was made from. The
benchmark saves the 27 largest classes of each launch. Swift Charts'
classes among them held 5.02 MB in 4,437 blocks in all three launches
before. After, they held 4.38 MB in 1,467 blocks in two launches and 2.75
MB in the third, where Swift Charts held one copy of its content in place
of two; whether that was the change or chance was not established. The
untyped allocations stayed where they were: 19.7 to 20.4 MB before and
20.2 to 20.6 MB after. Swift Charts expands a plot into the same content
for every point as it keeps for separate marks. The trial was not
committed; see "Tried and rejected".

It is the glyph cache. Of the 6.52 MB of glyph bitmaps, 6.1 MB was
allocated while SwiftUI was drawing text in the middle of an animated
change. The figures in the main window change with a rolling-digit
transition. A temporary build with that transition taken out of the main
window, not committed, held 0.46 MB of glyph bitmaps in 576 blocks in the
same kind of launch.

Why some launches fill the cache and others do not is an inference, not
something watched happening. Since pull request 89 the window can be on
screen before the portfolio's figures are ready, and then the figures roll
in; when they are ready first, nothing rolls. The comparisons fit that. In
the comparison above the baseline's six launches held 13.0 to 15.1 MB of
untyped allocations and the six of `experimental` 18.3 to 24.1 MB. In pull
request 95's first run, the three launches whose first window took 0.70 s
or longer held 16.2 to 17.5 MB and the other nine, at 0.45 to 0.56 s, held
21.6 to 23.5 MB. The first window's time does not decide it alone: one
launch of `experimental` in the comparison above took 0.86 s to its window
and held 21.8 MB.

Nothing was changed. The cache belongs to the system, the animation is
deliberate, and in normal use the app starts without a window, so the
figures are ready long before one is opened. (Corrected on 2026-11-13: the
app shows its main window at every launch, from `AppDelegate.swift`, so the
cache is filled in normal use as in the benchmark.) The cache was still held after
the 30 minutes of the soak below; whether it is ever emptied was not
measured beyond that. Pull request 98 has since made the rolling a setting.

### Soak: 30 minutes idle, baseline and `experimental`

One launch of each build watched for 30 minutes on 2026-11-12, the baseline
from 18:45 to 19:17 UTC and `experimental` at `c3c21ec` from 19:17 to 19:50,
on mains power with the display awake and unlocked. The load average was
4.8 before the first run, 3.5 between the two and 3.1 after the second.

```bash
STOCKBAR_DERIVED_DATA=build/bench/dd/48343a833a6d bash Scripts/perf/benchmark.sh --skip-build --commit-label 47c1bda --label milestone-1-soak-baseline --runs 1 --window 1800
STOCKBAR_DERIVED_DATA=build/bench/dd/8a91a4015cac bash Scripts/perf/benchmark.sh --skip-build --commit-label c3c21ec --label milestone-1-soak-head --runs 1 --window 1800
```

The two folders are the builds of those commits, made beforehand with
`benchmark.sh --build-only`.

| Metric | Baseline `47c1bda` | `experimental` at `c3c21ec` |
| --- | --- | --- |
| Idle memory (physical footprint), first five minutes | 132.2 MB | 101.4 MB |
| Idle memory (physical footprint), last five minutes | 135.9 MB | 101.7 MB |
| Idle memory, lowest and highest | 128.2 and 135.9 MB | 100.9 and 102.1 MB |
| Memory the app holds allocated, at the end | 67.1 MB | 55.4 MB |
| Idle CPU | 0.131 s/min | 0.136 s/min |
| Idle CPU wake-ups | 24.5 /min | 24.3 /min |
| Idle CPU power | 0.71 mW | 0.63 mW |
| Idle disk writes | 0.000 MB/min | 0.000 MB/min |

- Neither build's memory grows after the first four minutes.
  `experimental` rose by 0.4 MB 55 s into the window and by 0.8 MB at 230
  s, and then stayed where it was for the remaining 26 minutes. The first
  step falls where the app's log shows its startup check for missing price
  history, two minutes after launch. The baseline rose by 6.8 MB at 130 s
  and by 0.8 MB at 230 s, and then stayed at 135.9 MB.
- Idle CPU, wake-ups and CPU power are the same for the two builds, as far
  as one run of each can show.
- The two memory columns are one run of each build and are not a
  comparison; the table above is. The baseline's footprint takes two
  levels (plan item 9) and here it sat at the higher one. Its 67.1 MB
  allocated is also 6.8 MB above its soak of the night before (60.3 MB) and
  above all six of its launches in the comparison above (59.6 to 61.7 MB).
  Its heap listing at the end holds two copies of the main window chart's
  content where the earlier soak held one (3.25 MB against 1.62 MB), the
  chart's accessibility items (0.86 MB) and 2.4 MB more untyped
  allocations. So that chart was built a second time during the run. What
  made it do so was not established.
- Both runs used about four times the CPU of the baseline's soak of the
  night before (0.032 s/min, on the same build). That difference is
  therefore the Mac's state on the day and not the build, and its cause was
  not established. A soak is compared only with a soak run beside it.
- The glyph cache of the section above was still there at the end of
  `experimental`'s half hour: 19.0 MB of untyped allocations, and 1,625
  blocks of the size class its bitmaps fall in.

### Tests at the milestone

Run on 2026-11-12 on the branch that adds this section, whose app sources
and tests are those of `c3c21ec`:

- `bash script/develop.sh test`: 710 XCTest tests, 0 failures. The baseline
  had 682; the 28 more were added by the pull requests since.
- `bash script/develop.sh python-tests`: 66 Python helper tests pass.
- `python3 -B -m unittest discover -s Scripts/tests -p 'test_*.py'`: 75
  script tests pass.
- `bash script/develop.sh checks` and `docs-check` pass.
- `bash script/develop.sh build-release`: the Release configuration builds.

Nothing fails.

### What is left

In my judgement the candidates that remain are either small or change what
the app does:

- The app's own history in memory, 11.2 MB for the fixture's 7,000
  snapshots and 70,000 prices. Lowering it further means not keeping all
  history in memory and reading it when a view needs it. That is a change
  of architecture, not attempted here.
- The main window's chart, 5.4 MB for 730 points. Fewer points would lower
  it in proportion and would change what is drawn.
- The glyph cache, about 6 MB after a launch like the benchmark's, for the
  rolling digits. Pull request 98 has since added a switch that turns the
  rolling off.
- The Python helper, 71 MB while it is running. Pull request 86's switch
  lets it go between refreshes. The
  [Rust evaluation](#rust-evaluation-2026-11-12) covers taking the fetch
  out of Python, which waits for a decision.
- The launch peak of 244 MB, which is the first window being drawn (plan
  item 9).

### Recommendation

`experimental` is ready to be promoted to `testing` when the owner asks for
it. Nothing has been promoted and no pull request into `testing` or `main`
exists. What would go is pull requests 84, 85, 87 to 93 and 95, and this
log. Pull requests 86 and 94 are separate decisions, and 94 only makes
sense where 85 is.

Since this was written, pull requests 97 and 86 have been merged, so a
promotion would carry them too. Pull request 97 changes the release
workflow that `testing` and `main` use: its entry lists what changes for
testing builds and releases. Asked on 2026-11-12 whether to promote now,
the answer given was: not yet. The code is ready, and the gaps listed
below are the reason to wait. The Experimental channel can now close the
first three: run an experimental build on both of the owner's Macs, on the
real portfolio, through two trading days, and promote after that.

On 2026-11-13 the owner asked for the promotion without that wait, and for
pull request 94 to be merged first. The promotion therefore carries every
pull request from 84 to 98, and was made the same day: see
[Promotion to `testing`](#promotion-to-testing-2026-11-13). The list below
is unchanged by that: it is what the testing build has not been through.

What the measurements do not cover:

- One Mac and one macOS version, 27.2.1 on an M3 Pro, with made-up data.
  The app supports macOS 15.4 and later. Nothing here was run on an older
  system or on a real portfolio's store.
- The benchmark keeps live providers off. A refresh over the network, and
  the app recording prices through a trading day, were not measured.
- The longest run is 30 minutes idle.
- Pull request 89 changes the order of work at launch. It is covered by
  its tests and by every launch of every comparison since, not by a launch
  on a store that has grown over years.
- The popover chart fix was checked by drawing the app's own view with
  made-up data, not on the Mac that showed the fault.

## Promotion to `testing`, 2026-11-13

The owner asked for it on 2026-11-13. `experimental` at `3cf549b`, which is
pull requests 84 to 98, went into `testing` through
[pull request 100](https://github.com/jayjay181818/StockBar/pull/100). It
was merged with a merge commit, so each change is still a commit of its own
on `testing` and can be reverted alone.

- Branches. `testing` was `47c1bda` and is `2256b6c`, a merge commit whose
  parents are `47c1bda` and `3cf549b` and whose files are those of
  `3cf549b`. `main` was and is `75be612`. `experimental` stayed at
  `3cf549b`. The branch `appcast`, which holds the stable and testing feed,
  went from `4dfd943` to `e313178`: that is the release workflow adding the
  testing build. No version tag was made and nothing was released on the
  Stable channel.
- Pull request 99 was opened first, from `experimental` itself, and was
  closed unmerged. GitHub deletes a merged pull request's branch, and the
  repository's one ruleset protects only `main` and `testing` from
  deletion, so merging it would have deleted `experimental`. Pull request
  100 came from a temporary branch at the same commit,
  `feature/promote-experimental-to-testing`, which GitHub deleted at the
  merge. No repository setting was changed.
- CI. The CI workflow does not run for `experimental`, so it ran on this
  code for the first time here: on pull request 99, on pull request 100 and
  on `testing` after the merge. Both of its jobs passed all three times.
  One builds and tests with Xcode 26, which this code had not been built
  with before, and one with Xcode 27.
- The testing build. The merge published build 370.16 as the prerelease
  `testing-370.16`: `2256b6c` is the sixteenth commit on `testing` since
  the tag `v3.7.0`, fifteen changes and the merge. Checked after it: the
  feed's signature and the archive's signature are valid, the archive's
  length matches the feed, the unpacked app is build 370.16 of 3.7.0, its
  code signature verifies and its executable has no `__llvm_prf` section.
  The feed offers two builds, 370.16 on the Testing channel and the release
  370. This was the first testing build made by the workflow as pull
  request 97 changed it. The four experimental prereleases, 370.0.12 to
  370.0.15, were still listed afterwards.
- Experimental builds. Until `testing` is brought back, the next
  experimental build would be numbered 370.15.1: below testing build
  370.16, so a Mac that has 370.16 would not be offered it. The pull
  request that records this section merges `testing` into `experimental`
  with a merge commit. After it, experimental builds are numbered 370.16
  with a third part, which is above it.

### Comparison with the baseline

```bash
bash Scripts/perf/compare.sh 47c1bda 2256b6c --label milestone-2
```

Six launches a side in turns, between 01:18 and 01:50 UTC on 2026-11-13,
after the promotion, on macOS 27.2.1 and mains power. All twelve launches
ran with the screen unlocked and the display awake. The load average was
not recorded. These figures are not set beside Milestone 1's, which are
from another day: the baseline, the same build both times, loaded its
history in 1.88 s then and 1.20 s now.

| Metric | Before: median (range) | After: median (range) | Change | Verdict |
| --- | --- | --- | --- | --- |
| Idle memory (physical footprint) | 119.9 (102.3 to 134.9) MB | 95.8 (81.4 to 100.4) MB | -24.2 MB, -20.1% | lower (p = 0.002) |
| Idle memory the app holds allocated | 63.8 (60.7 to 64.5) MB | 54.5 (40.7 to 56.2) MB | -9.3 MB, -14.6% | lower (p = 0.002) |
| Peak memory, launch and history load | 285.1 (276.5 to 289.7) MB | 244.9 (241.3 to 248.4) MB | -40.1 MB, -14.1% | lower (p = 0.002) |
| Idle memory growth across the window | 0.0 (0.0 to 0.1) MB | 0.0 (-15.1 to 0.1) MB | +0.0 MB | no measurable change (p = 0.515) |
| Idle CPU | 0.093 (0.083 to 0.099) s/min | 0.089 (0.082 to 0.102) s/min | -0.005 s/min, -4.8% | no measurable change (p = 0.515) |
| Idle CPU wake-ups | 27 (23 to 31) /min | 24 (21 to 29) /min | -4 /min, -13.0% | no measurable change (p = 0.167) |
| Idle CPU power | 4.13 (3.38 to 4.65) mW | 3.97 (3.27 to 4.45) mW | -0.16 mW, -3.9% | no measurable change (p = 0.485) |
| Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
| Launch to first window | 0.58 (0.47 to 1.11) s | 0.52 (0.46 to 0.75) s | -0.06 s, -10.3% | no measurable change (p = 0.582) |
| Launch to history loaded | 1.20 (1.06 to 2.41) s | 0.63 (0.54 to 0.74) s | -0.57 s, -47.3% | lower (p = 0.002) |
| CPU from launch to the idle window | 2.64 (2.25 to 2.94) s | 1.88 (1.84 to 1.90) s | -0.76 s, -28.8% | lower (p = 0.002) |
| CPU energy from launch to the idle window | 7.85 (6.85 to 9.25) J | 6.07 (5.94 to 6.22) J | -1.78 J, -22.6% | lower (p = 0.002) |
| Python helper start to ready, no network | 0.31 (0.28 to 0.62) s | 0.29 (0.28 to 0.60) s | -0.02 s, -4.8% | no measurable change (p = 0.853) |
| Python helper start, CPU | 0.30 (0.28 to 0.37) s | 0.29 (0.28 to 0.38) s | -0.01 s, -1.7% | no measurable change (p = 0.859) |
| Python helper memory once started | 71.0 (70.9 to 71.0) MB | 71.0 (71.0 to 71.2) MB | +0.0 MB, +0.0% | no measurable change (p = 0.273) |

- The six rows that were lower at Milestone 1 are lower again, and no row
  is higher. Launch to first window, "possibly lower" at Milestone 1, shows
  no measurable change here.
- Pull requests 97, 86, 98 and 94 were merged after Milestone 1. Pull
  request 86's comparison stands for itself in its entry. Pull request 98
  was not benchmarked, at the owner's instruction, and pull requests 97 and
  94 change no code the benchmark runs. This is therefore the first run of
  the standard benchmark on an app that has pull request 98 in it. Both
  switches were as they ship: the helper kept for 15 minutes and the digits
  rolling.
- The baseline idled at two levels again (plan item 9): 102.3, 107.3 and
  108.3 MB in its first round and 131.5, 132.4 and 134.9 MB in its second.
- One launch of `2256b6c` is the low end of three ranges: it idled at 81.4
  MB, held 40.7 MB allocated and gave back 15.1 MB during the idle window.
  The app's log shows why. macOS sent it a memory pressure warning at
  01:41:15, about 20 seconds into that window, and between the samples at
  15 and 30 seconds its footprint fell from 95.9 to 80.8 MB. No other
  launch on either side had a warning. At the end of the window that launch
  held 8.6 MB of allocations with no class, where the launch before it held
  22.5 MB. What those were was not identified. The other five launches
  idled at 94.7 to 100.4 MB and held 53.5 to 56.2 MB allocated. Without the
  launch the two medians are 95.9 and 54.7 MB, and with or without it every
  launch of `2256b6c` is below every launch of the baseline in both rows.

Not measured for the promotion: a soak run, last made at Milestone 1 on
`c3c21ec`; anything on a real portfolio, on another Mac or on an older
macOS; a refresh over the network. No use of the testing build by the owner
is recorded here.

### Tests

- On the files that were promoted, run for pull request 94 before its
  merge: 724 XCTest tests with 0 failures, 66 Python helper tests and 91
  script tests pass; `checks`, `docs-check` and `build-release` pass; one
  full packaging run ended without error.
- The CI workflow's two jobs, three times, as above. Each runs the Python
  helper tests, the script tests, `checks`, a build, the XCTest tests, a
  Release build and a packaging run.

## Second promotion to `testing`, 2026-11-17

The owner asked for it on 2026-11-17, once this log was brought up to date
and the tests passed, and said they had run the experimental builds for
several days on a second Mac without a problem. `experimental` at
`be1bf79`, which is pull requests 101 to 110 and 112, went into `testing`
through [pull request 113](https://github.com/jayjay181818/StockBar/pull/113),
merged with a merge commit.

- Branches. `testing` was `2256b6c` and is `78c886b`, a merge commit whose
  parents are `2256b6c` and `be1bf79` and whose files are those of
  `be1bf79`. `2256b6c` was already in the history of `be1bf79`, through
  pull request 101, so the merge resolved nothing. `main` was and is
  `75be612`. The head was a temporary branch at `be1bf79`,
  `feature/promote-experimental-to-testing-2`, which GitHub deleted at the
  merge. No version tag was made and nothing was released on the Stable
  channel. No repository setting was changed.
- Tests, on `be1bf79` before the pull request was opened, macOS 27.2.1
  and Xcode 27.2: 732 XCTest tests with 0 failures, 69 Python helper tests
  pass, and `checks` and `build-release` pass. CI's two jobs, with Xcode 26
  and Xcode 27, passed on the pull request. It was the first time CI ran on
  pull requests 102 to 112, and their first build with Xcode 26.
- The testing build. The merge published build 370.29 as the prerelease
  `testing-370.29`: `78c886b` is the 29th commit on `testing` since the
  tag `v3.7.0`. Checked after it: the feed's signature and the archive's
  signature are valid, the archive's length, 7,196,394 bytes, matches the
  feed, the unpacked app is build 370.29 of 3.7.0, its code signature
  verifies and its executable has no coverage counters. The feed offers
  370.29 and 370.16 on the Testing channel and the release 370.
- Experimental builds. Until `testing` is brought back, experimental
  builds would be numbered below 370.29. The pull request that records
  this section starts from `78c886b`, so with it merged `experimental`
  holds the promotion's merge commit and its builds are numbered 370.29
  with a third part.
- Not measured for this promotion: the promoted commit as a whole against
  the baseline. The owner asked for the measuring to stop on 2026-11-16.
  Each pull request's own comparison is in its entry, and pull requests
  109 and 110 were measured together on the merged commit.
- Not exercised by hand: reopening the portfolio popover after each way it
  can close. The owner's use of the experimental builds on a second Mac is
  the only use on real data.

## Third promotion to `testing`, 2026-11-26

The owner asked for it on 2026-11-26 ("Lets do this"), answering the
lead's suggestion to look at build 382.3.26 and then promote. `experimental` at `21a1ed2`, which is pull requests 133
to 160 (the Glass redesign and the new Folync pages, with 160 added during
the promotion), went into `testing` through
[pull request 159](https://github.com/jayjay181818/StockBar/pull/159),
merged with a merge commit.

- Branches. `testing` was `0326182` and is `9cb4276`, a merge commit whose
  parents are `0326182` and `21a1ed2` and whose files are those of
  `21a1ed2`. The head was a temporary branch,
  `feature/promote-experimental-to-testing-3`, which was deleted at the
  merge. `main` is untouched. No version tag was made and nothing was
  released on the Stable channel. No repository setting was changed.
- CI. The pull request was opened at `0c77a54`. CI's first run, the first
  on this work since pull request 133, failed one test on Xcode 27: the
  sidebar footer's test expected "Updated 3 min…" where that macOS says
  "Updated 3m ago". Pull request 160 fixed the test, the promotion branch
  was moved forward to `21a1ed2`, and both CI jobs then passed.
- Tests locally: pull request 158's 1075 XCTest tests with 0 failures and
  its `checks`, `docs-check` and `build-release`, then 160's test class
  re-run on `21a1ed2` (15 tests, 0 failures).
- The testing build. The merge published build 382.31 as the prerelease
  `testing-382.31` ("StockBar 3.8.2 testing build 382.31"), with one
  archive, `Stockbar-382.31.zip`, of 8,394,423 bytes.
- Experimental builds. Until `testing` is brought back, experimental
  builds would be numbered below 382.31. Pull request 161 starts from
  `9cb4276` and is merged with a merge commit, so `experimental` then holds
  the promotion's merge commit.
- Not exercised by the lead: the owner's own data. That look is the
  owner's, on the experimental or testing build.

## Pull requests

Newest last. "Before" is the `experimental` commit the branch was based on,
"after" is the head of the pull request, measured in turns by
`Scripts/perf/compare.sh`.

### 84: Add the benchmark procedure, the baseline and the experimental log

- What: `Scripts/perf/benchmark.sh` (one build on fixed synthetic data),
  `Scripts/perf/compare.sh` (two commits in turns, with the before/after
  table), their tests, a rewritten `Scripts/README_PERFORMANCE.md`, the
  read-only sampler for a running app, and this log. No app code.
- Merged: 2026-11-12, squash commit `4f475ea`.
- Benchmark: the baseline above. The two sides are untouched `experimental`
  and this branch, whose app sources are identical, so the table shows the
  noise of the method.
- Testing: 682 XCTest tests, 66 Python helper tests and 70 script tests pass
  (15 of the script tests cover the benchmark data and the comparison
  report). `checks`, `docs-check` and `build-release` pass, and the shell
  scripts pass a syntax check. `measure_performance.sh` was run for 20
  seconds against the installed app to confirm it still reads the sampler.
  The benchmark itself was exercised by the baseline: 16 launches and the
  soak, every one with the display awake and unlocked.
- Known issues: none.
- Verdict: retained.

### 85: Stop building test-coverage counters into release builds

- What: one line of `Stockbar.xcscheme`. The scheme's test action no longer
  auto-creates a test plan. With that setting Xcode turned code coverage on
  for every build of the scheme, Release included, so the shipped executable
  carried coverage counters and maps: the installed 3.7.0 has nine such
  sections. No app code. `develop.sh coverage` asks for coverage explicitly
  and still reports it.
- Merged: 2026-11-12, squash commit `bd56486`.
- Benchmark: before `4f475ea`, after `88383b8`, six launches a side in turns
  on 2026-11-12 from 09:17 to 09:41 UTC, macOS 27.2.1, mains power with the
  battery charging from 12 percent.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Executable size | 24,982,936 bytes | 17,966,360 bytes | -7,016,576 bytes, -28.1% | lower: one build a side, no spread |
  | App bundle size | 29,116 KiB | 22,264 KiB | -6,852 KiB, -23.5% | lower: one build a side, no spread |
  | Coverage sections in the executable | 9, holding 1,125,163 bytes | 0 | removed | removed |
  | Idle memory (physical footprint) | 106.7 (104.9 to 110.6) MB | 105.5 (100.7 to 110.2) MB | -1.2 MB, -1.1% | no measurable change (p = 0.394) |
  | Idle memory the app holds allocated | 61.8 (61.5 to 62.7) MB | 61.6 (59.7 to 63.3) MB | -0.2 MB, -0.4% | no measurable change (p = 0.509) |
  | Peak memory, launch and history load | 282.7 (276.2 to 299.8) MB | 282.6 (275.9 to 287.4) MB | -0.1 MB, -0.0% | no measurable change (p = 0.937) |
  | Idle memory growth across the window | 0.0 (-3.6 to 0.0) MB | 0.0 (-0.1 to 0.1) MB | +0.0 MB | no measurable change (p = 0.727) |
  | Idle CPU | 0.086 (0.076 to 0.099) s/min | 0.092 (0.091 to 0.913) s/min | +0.006 s/min, +7.0% | no measurable change (p = 0.130) |
  | Idle CPU wake-ups | 26 (25 to 28) /min | 28 (25 to 221) /min | +2 /min, +5.7% | no measurable change (p = 0.517) |
  | Idle CPU power | 3.96 (3.47 to 4.94) mW | 4.28 (3.55 to 29.15) mW | +0.33 mW, +8.2% | no measurable change (p = 0.420) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.99 (0.90 to 1.39) s | 0.81 (0.49 to 1.05) s | -0.18 s, -18.2% | no measurable change (p = 0.132) |
  | Launch to history loaded | 1.64 (1.54 to 2.46) s | 1.65 (1.02 to 1.86) s | +0.01 s, +0.9% | no measurable change (p = 0.589) |
  | CPU from launch to the idle window | 2.62 (2.41 to 3.40) s | 2.52 (2.01 to 2.95) s | -0.11 s, -4.0% | no measurable change (p = 0.258) |
  | CPU energy from launch to the idle window | 7.92 (7.57 to 8.26) J | 7.56 (6.34 to 8.09) J | -0.35 J, -4.4% | no measurable change (p = 0.195) |
  | Python helper start to ready, no network | 0.32 (0.28 to 0.59) s | 0.30 (0.28 to 0.61) s | -0.01 s, -3.2% | no measurable change (p = 0.981) |
  | Python helper start, CPU | 0.30 (0.28 to 0.36) s | 0.30 (0.28 to 0.37) s | -0.01 s, -1.6% | no measurable change (p = 0.907) |
  | Python helper memory once started | 71.0 (70.9 to 71.0) MB | 71.0 (70.9 to 71.1) MB | +0.0 MB, +0.0% | no measurable change (p = 1.000) |

  The sizes are of the two apps the comparison built (`stat`, `du -sk` and
  `otool -l`). The rows this change was expected to move were the launch
  rows, since counters are updated on every code path. None moved by more
  than the noise: the benefit measured is the size alone.
- Testing: 682 XCTest tests with 0 failures, run plainly and again under
  `develop.sh coverage`, which still produced its report (30.54 percent of the
  app's lines). 66 Python helper tests and 70 script tests pass. `checks`,
  `docs-check` and `build-release` pass, and the Release executable from
  `build-release` has no coverage sections.
- Known issues: one "after" launch idled at 0.913 s/min with 221 wake-ups a
  minute. Its log shows the same events as every other launch and the cause
  was not found; the Mac had restarted after a macOS update 25 minutes
  earlier. Later comparisons show whether it recurs. Separately, running the
  tests from Xcode's own interface no longer gathers coverage unless it is
  turned on in the scheme's test options, and Xcode can write the setting back
  if the scheme is edited there.
- Verdict: retained, for the smaller executable. It changes no measured
  runtime figure.

### 86: Add a setting that lets the idle Python helper quit after 90 seconds

- What: a switch, **Settings → Advanced → Memory → Quit Python Helper When
  Idle**, off unless turned on. Off, `PythonWorkerPool` keeps an idle
  helper for 15 minutes, as it always has. On, it keeps it for 90 seconds:
  a helper serves one refresh pass or backfill burst and quits, and the
  next pass starts a new one.

  This pull request first made 90 seconds the fixed timeout, and stayed
  open because that trades memory for CPU. The owner asked on 2026-11-12
  for a switch in its place, so the branch was reworked: the fixed change
  is gone and the default is the old behaviour.

  The pool is given a closure in place of a fixed timeout and reads it at
  every look for idle workers, so the switch needs no restart. The switch
  also tells the pool at once, because the pool's idle check may be asleep
  for a quarter of the old timeout. The setting, `pythonHelper.quitWhenIdle`,
  is stored with the app's other defaults and travels with a settings
  export. The user guide and the architecture note describe it.

  Incidental: the pool's idle check now ends when its pool is gone. The old
  loop kept waking for ever once its pool had been deallocated, which only
  tests did.
- Merged: 2026-11-13, squash commit `2da80f2`. The merge published the
  prerelease `experimental-370.0.13`. Checked afterwards: the feed's
  signature and the archive's signature both verify against the
  `SUPublicEDKey` in `Info.plist`; the archive's length matches the feed;
  the unpacked app reports build 370.0.13 of version 3.7.0 and passes
  `codesign --verify --deep --strict`. `main`, `testing` and the `appcast`
  branch did not move.
- Benchmark, isolated: before `ec22bc3`, after `e3c85f8`, measured twice,
  each time six launches a side in turns on macOS 27.2.1 and mains power,
  all 24 launches with the screen unlocked and the display awake. Named in
  advance: no row expected to move. The isolated benchmark never starts the
  helper, so the pool's idle check never runs, and with the switch off the
  timeout is the old one in any case.

  No row moved the same way in both runs. The first run marked idle memory
  higher; the repeat put it 6.4 MB lower, which does not count as a change.
  It follows the cache of digit drawings, not this change; the reasoning is
  below the tables.

  First run, 23:03 to 23:36 UTC on 2026-11-12. The Mac was not left alone
  for it: a review subagent was reading files during both rounds of the
  "after" launches, and I was reading and editing files throughout.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 84.7 (83.6 to 89.5) MB | 90.7 (89.3 to 100.3) MB | +6.0 MB, +7.1% | higher (p = 0.004) |
  | Idle memory the app holds allocated | 46.3 (40.5 to 48.1) MB | 48.9 (47.4 to 55.4) MB | +2.5 MB, +5.4% | higher (p = 0.009) |
  | Peak memory, launch and history load | 234.8 (230.7 to 238.8) MB | 239.1 (228.5 to 245.6) MB | +4.2 MB, +1.8% | no measurable change (p = 0.180) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.6) MB | 0.0 (-2.3 to 0.1) MB | +0.0 MB | no measurable change (p = 0.394) |
  | Idle CPU | 0.090 (0.074 to 0.102) s/min | 0.084 (0.071 to 0.090) s/min | -0.006 s/min, -6.6% | no measurable change (p = 0.372) |
  | Idle CPU wake-ups | 24 (23 to 26) /min | 25 (24 to 27) /min | +1 /min, +4.2% | no measurable change (p = 0.416) |
  | Idle CPU power | 4.52 (4.10 to 4.72) mW | 4.28 (4.09 to 4.64) mW | -0.24 mW, -5.2% | no measurable change (p = 0.368) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 1.24 (0.78 to 1.73) s | 0.90 (0.57 to 1.17) s | -0.34 s, -27.8% | possibly lower (p = 0.041) |
  | Launch to history loaded | 1.25 (0.76 to 1.73) s | 0.85 (0.67 to 1.13) s | -0.40 s, -32.0% | possibly lower (p = 0.028) |
  | CPU from launch to the idle window | 1.86 (1.58 to 2.78) s | 1.75 (1.56 to 1.93) s | -0.10 s, -5.6% | no measurable change (p = 0.420) |
  | CPU energy from launch to the idle window | 5.54 (4.97 to 7.88) J | 5.53 (5.04 to 6.49) J | -0.01 J, -0.2% | no measurable change (p = 0.937) |
  | Python helper start to ready, no network | 0.38 (0.28 to 0.63) s | 0.29 (0.28 to 0.57) s | -0.08 s, -22.7% | no measurable change (p = 0.524) |
  | Python helper start, CPU | 0.34 (0.28 to 0.40) s | 0.29 (0.28 to 0.36) s | -0.05 s, -14.7% | no measurable change (p = 0.394) |
  | Python helper memory once started | 71.0 (70.8 to 71.1) MB | 71.0 (70.9 to 71.0) MB | -0.0 MB, -0.1% | no measurable change (p = 0.675) |

  Repeat, 23:40 UTC on 2026-11-12 to 00:13 UTC on 2026-11-13, with nothing
  else started on the Mac.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 94.4 (92.1 to 96.3) MB | 88.0 (85.6 to 96.7) MB | -6.4 MB, -6.8% | no measurable change (p = 0.065) |
  | Idle memory the app holds allocated | 52.2 (51.5 to 54.3) MB | 50.0 (47.1 to 55.0) MB | -2.2 MB, -4.3% | no measurable change (p = 0.065) |
  | Peak memory, launch and history load | 243.6 (236.3 to 260.4) MB | 248.1 (239.4 to 257.1) MB | +4.5 MB, +1.8% | no measurable change (p = 0.589) |
  | Idle memory growth across the window | 0.0 (-7.4 to 0.1) MB | 0.0 (0.0 to 3.5) MB | +0.0 MB | no measurable change (p = 0.727) |
  | Idle CPU | 0.086 (0.076 to 0.100) s/min | 0.094 (0.081 to 0.521) s/min | +0.008 s/min, +9.3% | no measurable change (p = 0.240) |
  | Idle CPU wake-ups | 24 (23 to 26) /min | 26 (22 to 110) /min | +1 /min, +4.1% | no measurable change (p = 0.420) |
  | Idle CPU power | 3.82 (3.19 to 4.61) mW | 4.50 (3.97 to 26.73) mW | +0.67 mW, +17.7% | no measurable change (p = 0.180) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.54 (0.48 to 0.80) s | 0.83 (0.51 to 1.40) s | +0.30 s, +56.1% | possibly higher (p = 0.050) |
  | Launch to history loaded | 0.62 (0.54 to 0.78) s | 0.81 (0.63 to 1.37) s | +0.19 s, +31.5% | possibly higher (p = 0.045) |
  | CPU from launch to the idle window | 1.85 (1.71 to 1.99) s | 1.92 (1.87 to 2.51) s | +0.06 s, +3.5% | no measurable change (p = 0.082) |
  | CPU energy from launch to the idle window | 5.88 (5.50 to 6.38) J | 5.97 (5.75 to 6.58) J | +0.09 J, +1.6% | no measurable change (p = 0.485) |
  | Python helper start to ready, no network | 0.29 (0.28 to 0.60) s | 0.36 (0.28 to 0.73) s | +0.07 s, +24.1% | no measurable change (p = 0.671) |
  | Python helper start, CPU | 0.29 (0.28 to 0.36) s | 0.35 (0.27 to 0.48) s | +0.06 s, +22.8% | no measurable change (p = 0.470) |
  | Python helper memory once started | 71.0 (70.9 to 71.1) MB | 71.0 (70.3 to 71.2) MB | -0.1 MB, -0.1% | no measurable change (p = 0.491) |

  Four rows were marked across the two runs, none of them the same way in
  both:

  - Idle memory and the memory the app holds allocated were higher in the
    first run (+6.0 MB, p = 0.004, and +2.5 MB, p = 0.009). In the repeat
    they were 6.4 MB and 2.2 MB lower, which is no measurable change (p =
    0.065 for each).
  - Launch to first window and launch to history loaded were possibly lower
    in the first run (-0.34 s and -0.40 s) and possibly higher in the repeat
    (+0.30 s and +0.19 s).

  The memory rows follow the launch times: in each run the side whose window
  came up sooner held more. What differs between the 24 launches is the
  number of allocated blocks of 2 to 4 KB, counted from each launch's saved
  `heap` output: 719 to 6,466 of them, 1.9 to 16.1 MB. `experimental` had
  719 to 6,116 and this branch 3,282 to 6,466. The bytes in blocks of every
  other size came to 40.5 to 42.4 MB for `experimental` and 40.8 to 42.0 MB
  for this branch. The sooner the window, the more such blocks (rank
  correlation -0.83 over the 24 launches), and the more blocks, the more
  idle memory (0.85).

  Blocks of that size are what the glyph cache holds for the rolling digits.
  [Milestone 1](#milestone-1-2026-11-12) named 3,267 of them, 6.52 MB, by
  their allocation stacks, and inferred that a launch whose window is up
  before the figures are ready fills the cache. That the blocks counted here are
  glyph bitmaps is taken from that measurement; these launches recorded no
  allocation stacks. Why one side's windows came up sooner in each run was
  not found. It was `experimental`'s in one run and this branch's in the
  other.
- On real data, before only. The installed 3.7.0, which keeps the helper
  for 15 minutes, was sampled every 10 seconds for 33 minutes from 09:49
  UTC on 2026-11-12 with
  `bash Scripts/measure_performance.sh --duration 1980`, for the first
  version of this pull request.

  | Metric | Installed 3.7.0 on real data |
  | --- | --- |
  | App memory | 82.9 MB (78.5 to 92.3) |
  | Helper memory while running | 92.1 MB |
  | Helper running | in 100 percent of 199 samples |
  | App and helper together | 175.1 MB on average, 184.5 MB at most |
  | App CPU | 0.18 s/min |
  | Helper CPU | 0.02 s/min |
  | App wake-ups | 34 /min |

  The helper holds more than the app and, while markets are open, never
  quits.
- On real data, with the switch on: not measured. It needs this build run
  on the real portfolio in place of the installed app, which is not done
  unattended. Expected, and theoretical until measured: at the default
  five-minute refresh the helper would be running about a third of the time
  (see [Before the transition](#before-the-transition)), so app and helper
  would average about 114 MB in place of 175 MB. Each pass would start a
  new helper, 0.30 s of CPU by the isolated measurement, which is 0.06
  s/min on top of the 0.20 s/min the two processes use now. An experimental
  build on the owner's Mac, sampled with `measure_performance.sh` with the
  switch off and then on, would turn this into a measurement.
- Testing: 722 XCTest tests with 0 failures. Five are new, all in the
  pool's class: an idle worker stops after the timeout and so does the one
  that replaces it; a worker used again inside the timeout keeps running; a
  shortened timeout applies at once; a lengthened one keeps the worker that
  is idle now; and the app's own pool follows the key the switch writes, in
  the app's store, which under XCTest is an isolated suite. 66 Python
  helper tests and 89 script tests pass. `checks`, `docs-check` and
  `build-release` pass.

  The switch was looked at in the real Settings window of an isolated copy
  (made-up data, live providers off), driven by Sonnet. It sits between
  Python and Diagnostics, starts off, and turns on and off with no alert
  and nothing else changing. Turned on, the copy's own settings file held
  the key as true. In a window 760 points high the Memory section is below
  the bottom edge and the page scrolls to it and to Diagnostics. That was
  confirmed by pressing the scroll bar's page button through the
  accessibility interface: made-up wheel events did not move the page, and
  a real trackpad was not tried. The description's final wording, corrected
  after this check (see Review), was not looked at on screen; the check of
  the next pull request, which adds a second switch to the section, reads
  both.
- Review: my own reading of the diff found one race, fixed in `6c9543d`. An
  idle check that had finished sleeping and was waiting for the pool when
  the timeout changed could clear the slot that by then held its successor,
  and a later request would have started a second check beside it. One
  independent review by Opus followed, of the diff at `6c9543d`. It found
  no defect in the pool and confirmed the fix. It did find that the
  switch's description and the documents promised too much: a quote for a
  closed London or US listing is refetched only every 30 minutes, so
  "refreshing every minute keeps the helper running" holds only while
  markets are open, and a 15-minute interval sits on the edge of the
  15-minute timeout. It also found that two tests could not fail for the
  reason their names gave. All of that was corrected in `e3c85f8`, which is
  the commit measured.
- Known issues:
  - What the switch saves on real data is expected, not measured.
  - On, at a refresh interval of five minutes or longer, every refresh pass
    starts a helper: about a third of a second of CPU, and that pass's
    first price arrives about as much later.
  - "90 seconds" is 90 to about 113: the pool looks for idle workers every
    quarter of the timeout.
  - The race fixed in `6c9543d` has no test. Causing it on purpose needs
    control over the moment a task resumes.
- Verdict: retained, as a switch that is off unless turned on. Whether it
  should be on by default is the owner's decision. I would turn it on where
  memory matters more than about 0.06 s/min of CPU.

### 87: Read stored portfolio history in batches

- What: `CoreDataHistoricalDataService` fetched the whole portfolio history
  at once, so every snapshot's managed objects, with their positions, were
  alive together beside the values built from them. It now lists the
  snapshots oldest first and converts 500 at a time, letting go of each batch
  before the next. Both `fetchPortfolioSnapshots(from:to:)` and
  `fetchAllPortfolioSnapshots()` read this way. Three new tests.
- Merged: 2026-11-12, squash commit `3f59dc6`.
- Benchmark: before `bd56486`, after `1dd6455`, six launches a side in turns
  on 2026-11-12 from 10:39 to 11:09 UTC, macOS 27.2.1, mains power. The row
  it was meant to move is the peak memory of launch and history load. The Mac
  was not quiet: a system file-syncing process and the window server kept
  between one and two cores busy throughout (load average about 6), for both
  sides alike.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 128.9 (104.3 to 132.2) MB | 113.1 (100.0 to 116.2) MB | -15.8 MB, -12.3% | possibly lower (p = 0.026) |
  | Idle memory the app holds allocated | 60.2 (55.1 to 61.5) MB | 61.5 (60.1 to 62.1) MB | +1.3 MB, +2.2% | no measurable change (p = 0.087) |
  | Peak memory, launch and history load | 283.8 (277.0 to 300.3) MB | 267.4 (265.2 to 269.7) MB | -16.4 MB, -5.8% | lower (p = 0.002) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.1) MB | 0.0 (0.0 to 0.1) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.075 (0.065 to 0.086) s/min | 0.082 (0.072 to 0.099) s/min | +0.007 s/min, +8.6% | no measurable change (p = 0.333) |
  | Idle CPU wake-ups | 28 (23 to 31) /min | 30 (28 to 32) /min | +1 /min, +3.5% | no measurable change (p = 0.348) |
  | Idle CPU power | 4.58 (4.20 to 5.14) mW | 4.46 (4.00 to 5.60) mW | -0.13 mW, -2.8% | no measurable change (p = 0.615) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.86 (0.50 to 1.24) s | 0.58 (0.52 to 1.54) s | -0.28 s, -32.9% | no measurable change (p = 0.556) |
  | Launch to history loaded | 1.75 (1.56 to 2.17) s | 1.47 (1.13 to 2.48) s | -0.28 s, -16.2% | no measurable change (p = 0.381) |
  | CPU from launch to the idle window | 2.47 (2.20 to 3.30) s | 2.29 (1.91 to 3.29) s | -0.18 s, -7.3% | no measurable change (p = 0.331) |
  | CPU energy from launch to the idle window | 7.95 (7.48 to 8.37) J | 6.68 (5.55 to 8.38) J | -1.27 J, -15.9% | no measurable change (p = 0.093) |
  | Python helper start to ready, no network | 0.35 (0.30 to 0.73) s | 0.34 (0.29 to 0.62) s | -0.01 s, -4.3% | no measurable change (p = 0.673) |
  | Python helper start, CPU | 0.33 (0.30 to 0.44) s | 0.34 (0.29 to 0.40) s | +0.01 s, +1.5% | no measurable change (p = 0.931) |
  | Python helper memory once started | 71.1 (71.0 to 71.2) MB | 71.0 (70.8 to 71.2) MB | -0.1 MB, -0.2% | no measurable change (p = 0.080) |

  Idle memory came out "possibly lower". That needs a repeat before it
  counts, and it is not claimed. The six "before" launches idled at 104.3,
  126.7, 128.0, 129.8, 130.8 and 132.2 MB and the six "after" launches at
  100.0, 102.4, 111.9, 114.3, 115.4 and 116.2 MB. The "before" build idles
  near 105 MB after some launches and near 130 MB after others: it did so in
  pull request 86's comparison too, on both sides, which ran the same code at
  launch. Six launches a side cannot separate that from an effect of this
  size. Later comparisons have this change on their "before" side and will
  show whether it holds.
- Testing: 685 XCTest tests with 0 failures (three new), 66 Python helper
  tests and 70 script tests pass. `checks`, `docs-check` and `build-release`
  pass. The new tests read a history longer than one batch, compare batch
  sizes against each other, and read from an SQLite store whose rows are not
  in date order.
- Known issues: none.
- Verdict: retained, for the lower peak.

### 88: Record the Rust evaluation and add the script behind its figures

- What: the [Rust evaluation](#rust-evaluation-2026-11-12) below, and
  `Scripts/perf/helper_layers.py`, which measures what each layer of the
  Python helper's imports holds beside two compiled programs that start and
  wait (`native_floor.swift`, `native_floor.rs`). `helper_cost.py` now shares
  its process-starting code with the new script; three starts before and
  three after gave the same figures (0.28 to 0.30 s, 70.8 to 71.1 MB). Its
  one visible difference: the message when the started program exits without
  answering now names the program instead of saying "The worker". A
  section in `Scripts/README_PERFORMANCE.md` and four script tests.
- Merged: 2026-11-12, squash commit `4ff7566`.
- Benchmark: not run. No file that goes into the app changes (nothing under
  `Stockbar/`, `StockbarTests/` or `Stockbar.xcodeproj`), so before and after
  are the same app and all fifteen rows are "not measured". The figures this
  pull request does carry are the layer table in the evaluation.
- Testing: 74 script tests pass (four new), and `checks` and
  `docs-check` pass. The app's own tests were not run again: no file they
  build changes.
- Known issues: none.
- Verdict: retained as a record. No Rust was adopted.

### 89: Read the stored history at launch away from the main thread

- What: at launch the app read each symbol's stored price history and took
  it into memory one symbol at a time on the main actor, then read the
  portfolio history, while the main thread was also building the first
  window. A detached task now reads and thins every symbol's history away
  from the main actor and reads the portfolio history without waiting for the
  prices to be taken. Only taking the results into memory runs on the main
  actor. A stored series is taken as it is when nothing is in memory for its
  symbol, without the merge every series used to go through.
- The defect this found and closes: because every symbol is now read before
  any is taken, the launch read could finish after the UK price scale repair
  had rewritten, invalidated and reloaded a symbol, and put the old rows back
  for the session. `invalidatePriceData` now counts its calls, and a read that
  began before a symbol was invalidated is not taken for that symbol. Eight
  new tests cover the read, the taking into memory, and both orders of a
  stale read and the reload.
- Behaviour change: stored price history used to appear symbol by symbol as
  it was read. It now appears for every symbol together, once all are read.
  All of it is in memory sooner (the table below). How much later the first
  symbol's history arrives than it used to was not measured; it is in memory
  within the 0.60 s the whole load now takes.
- Merged: 2026-11-12, squash commit `8140395`.
- Benchmark: before `4ff7566`, after `6925741`, ten launches a side in turns
  on 2026-11-12 from 11:23 to 12:13 UTC, macOS 27.2.1, mains power. The rows
  it was meant to move are launch to history loaded and launch to first
  window. All twenty launches ran with the screen locked and eighteen with
  the display asleep; the last two "before" launches had the display awake.
  See "Breaks in the measuring environment". When the run began a system
  media-analysis process was using more than two cores (load average 3.9).

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 123.2 (117.5 to 129.9) MB | 116.2 (113.4 to 122.4) MB | -6.9 MB, -5.6% | lower (p = 0.000) |
  | Idle memory the app holds allocated | 63.0 (62.5 to 63.4) MB | 63.3 (62.9 to 63.5) MB | +0.3 MB, +0.6% | possibly higher (p = 0.020) |
  | Peak memory, launch and history load | 261.8 (259.9 to 269.7) MB | 253.0 (251.5 to 259.2) MB | -8.8 MB, -3.3% | lower (p = 0.000) |
  | Idle memory growth across the window | 0.0 (-0.2 to -0.0) MB | 0.0 (0.0 to 0.2) MB | +0.0 MB | no measurable change (p = 0.263) |
  | Idle CPU | 0.162 (0.089 to 0.198) s/min | 0.168 (0.154 to 0.223) s/min | +0.006 s/min, +3.7% | no measurable change (p = 0.210) |
  | Idle CPU wake-ups | 25 (23 to 31) /min | 28 (22 to 30) /min | +2 /min, +10.0% | no measurable change (p = 0.298) |
  | Idle CPU power | 1.38 (1.29 to 4.21) mW | 1.31 (1.25 to 1.50) mW | -0.08 mW, -5.8% | no measurable change (p = 0.117) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.42 (0.37 to 0.95) s | 0.42 (0.38 to 0.66) s | +0.01 s, +1.2% | no measurable change (p = 0.959) |
  | Launch to history loaded | 1.03 (0.85 to 1.70) s | 0.60 (0.51 to 0.86) s | -0.43 s, -41.3% | lower (p = 0.000) |
  | CPU from launch to the idle window | 2.23 (1.98 to 3.00) s | 1.67 (1.59 to 1.87) s | -0.56 s, -24.9% | lower (p = 0.000) |
  | CPU energy from launch to the idle window | 7.12 (6.47 to 8.14) J | 5.32 (5.04 to 5.65) J | -1.80 J, -25.3% | lower (p = 0.000) |
  | Python helper start to ready, no network | 0.31 (0.23 to 0.61) s | 0.25 (0.24 to 0.48) s | -0.06 s, -19.4% | no measurable change (p = 0.835) |
  | Python helper start, CPU | 0.29 (0.23 to 0.38) s | 0.24 (0.24 to 0.28) s | -0.04 s, -14.0% | no measurable change (p = 0.331) |
  | Python helper memory once started | 71.0 (70.9 to 71.1) MB | 71.0 (70.9 to 71.0) MB | +0.0 MB, +0.0% | no measurable change (p = 1.000) |

  Of the two rows it was meant to move, launch to history loaded is lower by
  0.43 s and launch to first window did not move. So history is ready
  sooner, but the first window does not appear sooner, at least with the
  screen locked.

  Four rows moved that were not predicted: CPU and CPU energy from launch to
  the idle window (a quarter lower), peak memory (8.8 MB lower) and idle
  memory (6.9 MB lower). The likely reason, from reading the code and not
  measured separately: the old path built a set of every stored row's
  timestamp and merged before thinning, for every symbol, and the new path
  thins once and skips the merge when nothing is in memory. That is work
  removed, not only work moved. Idle memory has shown two levels for one
  build before (pull request 87), so that row carries less weight than the
  others.

  Without the two launches that had the display awake, the eight remaining
  "before" launches give the same picture: history loaded in 0.96 s against
  0.60 s, launch CPU 2.20 s against 1.67 s, peak memory 261.3 MB against
  253.0 MB.

  The heap the app holds allocated came out "possibly higher", by 0.3 MB.
  That needs a repeat before it counts and was not repeated. If it is real,
  it is 0.3 MB inside an idle memory figure that fell by 6.9 MB. The
  milestone comparison against the baseline will show the heap row again.
- Testing: 693 XCTest tests with 0 failures (eight new), 66 Python helper
  tests and 74 script tests pass. `checks`, `docs-check` and `build-release`
  pass. Every launch on both sides of the comparison logged the same 7000
  portfolio snapshots loaded.
- Reviews: two independent reviews by Opus. The first found the defect
  above. The second, of the corrected branch, found no defect and pointed out
  the behaviour change above, which the description had not mentioned.
- Known issues: two small ones, left as they are. No test pins that a read
  notes the invalidation count before it starts and not after; the manager
  cannot be built around a stand-in store in a test. And a symbol skipped
  because it was invalidated is not logged, while the "Loaded stored price
  history for N symbols" line still counts it.
- Verdict: retained, for history loaded 0.43 s sooner and a quarter less CPU
  at launch.

### 90: Keep each portfolio snapshot's positions in a sorted array

- What: every portfolio snapshot the app keeps in memory carries the
  positions held at that moment, and the app keeps thousands of snapshots.
  The positions were a dictionary keyed by symbol, whose hash table for 15
  holdings takes about 2.3 KB. They are now `PositionSnapshots`, an array
  sorted by symbol that is searched by halving: 56 bytes a position, about
  0.9 KB for 15. It is still written to and read from JSON as a dictionary
  keyed by symbol, and what is stored in Core Data does not change.
- Behaviour differences, none of them reachable from what the app writes
  today. Positions are now walked in order of symbol where a dictionary's
  order was arbitrary, so the risk figures add their terms in a fixed order.
  If one stored snapshot ever held the same symbol twice, the first is now
  kept, where the survivor used to depend on the order of an unordered set;
  nothing writes such a snapshot. A dictionary entry filed under a key other
  than its position's own symbol takes the key as its symbol, so it is still
  found under that key.
- Merged: 2026-11-12, squash commit `612d214`.
- Benchmark: before `8140395`, after `3f50c11`, six launches a side in turns
  on 2026-11-12 from 12:32 to 13:04 UTC, macOS 27.2.1, mains power. The row
  it was meant to move is the idle memory the app holds allocated, expected
  about 11 MB lower. All twelve launches ran with the screen unlocked and
  the display awake. When the run began Spotlight indexing and the file
  provider were using about three cores between them (load average 9.6,
  falling to about 6 by the end).

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 110.0 (108.0 to 111.6) MB | 95.8 (92.4 to 102.3) MB | -14.2 MB, -13.0% | lower (p = 0.002) |
  | Idle memory the app holds allocated | 62.9 (61.9 to 63.3) MB | 52.2 (51.6 to 53.4) MB | -10.7 MB, -17.0% | lower (p = 0.002) |
  | Peak memory, launch and history load | 271.1 (258.4 to 273.8) MB | 250.2 (240.7 to 261.0) MB | -20.8 MB, -7.7% | lower (p = 0.004) |
  | Idle memory growth across the window | 0.0 (-4.2 to 0.0) MB | 0.0 (0.0 to 0.0) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.079 (0.067 to 0.091) s/min | 0.082 (0.067 to 0.085) s/min | +0.003 s/min, +3.2% | no measurable change (p = 0.911) |
  | Idle CPU wake-ups | 28 (25 to 33) /min | 28 (24 to 30) /min | +0 /min, +1.8% | no measurable change (p = 1.000) |
  | Idle CPU power | 4.41 (3.88 to 4.95) mW | 4.04 (3.88 to 4.35) mW | -0.38 mW, -8.5% | no measurable change (p = 0.097) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.63 (0.46 to 1.00) s | 0.58 (0.48 to 1.32) s | -0.05 s, -7.9% | no measurable change (p = 0.974) |
  | Launch to history loaded | 0.75 (0.56 to 1.00) s | 0.62 (0.53 to 1.30) s | -0.13 s, -17.3% | no measurable change (p = 0.942) |
  | CPU from launch to the idle window | 1.83 (1.71 to 1.99) s | 1.77 (1.60 to 2.08) s | -0.06 s, -3.6% | no measurable change (p = 0.701) |
  | CPU energy from launch to the idle window | 5.59 (5.29 to 6.12) J | 5.47 (5.14 to 6.23) J | -0.12 J, -2.1% | no measurable change (p = 0.613) |
  | Python helper start to ready, no network | 0.33 (0.28 to 0.63) s | 0.28 (0.27 to 0.56) s | -0.05 s, -16.7% | no measurable change (p = 0.173) |
  | Python helper start, CPU | 0.30 (0.28 to 0.39) s | 0.28 (0.27 to 0.35) s | -0.03 s, -9.8% | no measurable change (p = 0.180) |
  | Python helper memory once started | 71.0 (71.0 to 71.1) MB | 71.0 (70.9 to 71.0) MB | -0.1 MB, -0.1% | possibly lower (p = 0.043) |

  The row it was meant to move fell by 10.7 MB, a sixth of the allocated
  heap. Two rows moved that were not predicted. Idle memory fell by 14.2 MB,
  more than the allocated heap did. Peak memory fell by 20.8 MB: the history
  load now builds an array for each snapshot where it built a dictionary.
  No CPU, energy or launch-time row moved.

  The helper's memory came out "possibly lower", by 0.1 MB. The helper is
  the same code on both sides, so that row is chance.

  A first attempt at 12:19 UTC stopped before measuring anything. The
  warm-up launch of the "before" build did not finish its first history
  calculation within the 180 s the script allows. The Mac's load average was
  between 46 and 64 at the time, from system work (the file provider, media
  analysis, on-device inference, a backup and Spotlight) on top of a test
  run and two builds for this pull request that had just finished. The
  script deleted the app's log with its temporary storage, so the cause is
  not established. Afterwards the same build completed a warm-up launch in
  62 s at 12:26 UTC, and all four warm-up launches of the second attempt
  completed. No crash report was written.
- Testing: 701 XCTest tests with 0 failures (eight new), 66 Python helper
  tests and 74 script tests pass. `checks`, `docs-check` and `build-release`
  pass. Every launch on both sides of the comparison logged the same 7000
  portfolio snapshots loaded.
- Review: one independent review by Opus, of the branch after
  `experimental` was merged into it and before anything was built. It found
  that the tests no longer compiled: two lines added by pull request 87
  still used the dictionary. Fixed before the test run. It found no defect
  in the change, confirmed that nothing else uses the dictionary's
  interface, and checked the memory arithmetic.
- Known issues: two small ones, left as they are. `symbols` builds an array
  where the dictionary's `keys` was a view; its two callers each use it once
  per snapshot for an export or an analysis. And no test pins the
  `compositionHash` text written with each stored snapshot. It is built from
  the same strings in the same sorted order as before, and nothing in the
  app reads it back.
- Verdict: retained, for 10.7 MB less allocated memory at idle and 20.8 MB
  less at the launch peak, with nothing given up.

### 91: Keep the app's log when a benchmark launch fails

- What: `Scripts/perf/benchmark.sh` runs the app against temporary storage
  and deletes that storage when it ends, the app's log with it. A run that
  failed therefore left nothing to explain the failure, which is what
  happened to the first attempt at pull request 90's comparison. A run that
  does not finish, whether it fails or is stopped, now copies the log to
  `app-failed.log` in its results folder, with anything the app printed as
  `app-output-failed.log`, and says where. The temporary storage is still deleted. The script's two error
  messages for a launch that exits or times out no longer name the log file
  that is about to be deleted. A successful run is unchanged. One new script
  test runs the script against a stand-in for the
  app that exits at once, and a paragraph in `Scripts/README_PERFORMANCE.md`
  describes it.
- Merged: 2026-11-12, squash commit `248280a`.
- Benchmark: not run. No file that goes into the app changes (nothing under
  `Stockbar/`, `StockbarTests/` or `Stockbar.xcodeproj`), so before and after
  are the same app and all fifteen rows are "not measured".
- Testing: 75 script tests pass (one new). The new test fails against the
  script as it was and passes with the change. `checks` and `docs-check`
  pass. A run stopped with a termination signal during its warm-up, tried by
  hand against a stand-in that stays running, kept the log as well; no
  script test covers that case. One real run of the changed script on its normal path (one launch of
  the build of `3f50c11`) ended without error, saved `app.log` and its
  figures as before, wrote no `app-failed.log`, and left no temporary
  storage or app process behind. The app's own tests were not run again: no
  file they build changes.
- Known issues: the new test needs macOS and its developer tools, and is
  skipped without them. The first time it runs in a checkout it compiles the
  benchmark's small measuring tool into `build/`, which takes a few seconds.
- Verdict: retained. It does not explain the failure that prompted it; it
  means the next one can be explained.

### 92: Read the portfolio chart's history without each snapshot's positions

- What: the chart of the portfolio's value, in the menu bar popover and the
  Overview window, draws one point per stored snapshot from its date, total
  and currency. For any range longer than a day, unless the value comes from
  Folync, it read whole snapshots from Core Data, each with the positions held at that moment: one more row per
  holding for every row it used, fifteen in the benchmark's portfolio. It now
  asks Core Data for those three columns only
  (`fetchPortfolioValues`, returning `StoredPortfolioValue`). The rows, their
  order and the defaults for a missing date or currency are the same. The
  chart reloads whenever the stored prices or portfolio history change while
  it is on screen, three or four times during a launch, so the read recurs.
  The function the chart used to call and the overload that turned whole
  snapshots into chart points had no other caller and are removed. The only
  difference to see is in the log, where the chart's read now says
  "portfolio values" where it said "portfolio snapshots".
- Merged: 2026-11-12, squash commit `f0fdcc3`.
- Benchmark: before `248280a`, after `42fea1f`, six launches a side in turns
  on 2026-11-12 from 13:43 to 14:16 UTC, macOS 27.2.1, mains power, all
  twelve launches with the screen unlocked and the display awake. Named in
  advance: the chart's own read of a week of stored history, timed from the
  app's log and expected several times shorter than about 25 ms; no standard
  row was expected to move. The Mac was busy with other work throughout
  (load average 7.9 at the start, after waiting 80 s for it to fall below
  8).

  | Change-specific row | Before | After | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | The chart's read of a week of stored history (730 or 731 snapshots): median (range) | 24 (21 to 30) ms, 20 reads | 2 (1 to 3) ms, 19 reads | -22 ms, about a twelfth of the time | lower: the longest read after is shorter than the shortest before |

  That row is the time between the two lines the read writes to the app's
  log, taken from the measured launches of the same comparison.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 89.7 (87.5 to 99.3) MB | 87.8 (83.0 to 92.0) MB | -1.8 MB, -2.1% | no measurable change (p = 0.225) |
  | Idle memory the app holds allocated | 50.5 (46.9 to 51.6) MB | 51.4 (43.8 to 56.4) MB | +0.8 MB, +1.6% | no measurable change (p = 0.515) |
  | Peak memory, launch and history load | 238.1 (235.1 to 245.8) MB | 240.0 (237.9 to 242.5) MB | +1.9 MB, +0.8% | no measurable change (p = 0.186) |
  | Idle memory growth across the window | 0.0 (-1.7 to 5.9) MB | 0.0 (-0.2 to 3.2) MB | +0.0 MB | no measurable change (p = 0.879) |
  | Idle CPU | 0.093 (0.076 to 1.724) s/min | 0.091 (0.087 to 0.398) s/min | -0.003 s/min, -2.7% | no measurable change (p = 0.732) |
  | Idle CPU wake-ups | 28 (26 to 501) /min | 30 (25 to 43) /min | +2 /min, +5.4% | no measurable change (p = 0.972) |
  | Idle CPU power | 4.54 (4.40 to 89.35) mW | 4.67 (3.97 to 12.87) mW | +0.13 mW, +3.0% | no measurable change (p = 0.818) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 1.14 (0.94 to 1.25) s | 1.08 (0.86 to 1.36) s | -0.06 s, -5.3% | no measurable change (p = 0.660) |
  | Launch to history loaded | 1.08 (0.89 to 1.20) s | 1.06 (0.85 to 1.34) s | -0.03 s, -2.8% | no measurable change (p = 0.894) |
  | CPU from launch to the idle window | 2.06 (1.93 to 2.16) s | 2.08 (1.99 to 2.14) s | +0.02 s, +0.7% | no measurable change (p = 0.712) |
  | CPU energy from launch to the idle window | 6.09 (6.01 to 6.44) J | 6.30 (5.64 to 6.50) J | +0.21 J, +3.5% | no measurable change (p = 0.485) |
  | Python helper start to ready, no network | 0.31 (0.30 to 0.74) s | 0.37 (0.31 to 0.71) s | +0.06 s, +19.4% | no measurable change (p = 0.455) |
  | Python helper start, CPU | 0.30 (0.29 to 0.42) s | 0.35 (0.30 to 0.43) s | +0.04 s, +14.8% | no measurable change (p = 0.251) |
  | Python helper memory once started | 71.0 (69.9 to 71.1) MB | 71.0 (71.0 to 71.3) MB | -0.0 MB, -0.1% | no measurable change (p = 0.760) |

  The read fell as expected and no standard row moved, also as expected:
  three or four reads of 24 ms come to less than 0.1 s, away from the main
  thread, in a launch that uses 2 s of CPU.

  Not measured, so theoretical: the saving for longer ranges and over a day
  of use. In these twelve launches the app's own launch read of all 7000
  snapshots with their positions took a median of 246 ms (222 to 332 ms).
  That is what the chart's read cost for the range "All" before this change;
  the new read was not timed at that size. How often the chart reloads in
  real use was not counted: the benchmark runs without market data.

  One launch on each side had a busier idle window than the rest (501 CPU
  wake-ups a minute before and 43 after, against 25 to 31 in the other ten).
  The cause is not established. The verdicts compare ranks, so a single
  launch does not decide a row. Launch times are longer than in pull request
  90's comparison for the same reason as the load average: the first window
  took 1.14 s here with the same app sources that took 0.58 s there.

  A first comparison, of an earlier head of the branch (`d6a5f96`), was
  stopped part of the way through its first round when the session running
  it restarted. It
  left the app's log behind, as pull request 91 arranged, and the log showed
  a fault in that version: over seven reads in two launches the new read
  took a median of 21 ms, between 5 and 53 ms, no better than the old one.
  It ran on the main actor and went back to it between its steps, waiting
  its turn each time while the launch kept the main actor busy. The read
  now runs clear of the main actor, as the read it replaces did
  (`readPortfolioValues`), and the figures above are of that version.
- Testing: 703 XCTest tests with 0 failures (two new: the values read
  returns the same snapshots in the same order as the read with positions,
  on a SQLite store, and it returns nothing when the fetch fails). `checks`,
  `docs-check` and `build-release` pass at `42fea1f`. The 66 Python helper
  tests and 75 script tests were run at `d6a5f96`, one commit earlier, and
  pass; that last commit changed two Swift files only. Every measured launch
  on both sides logged the same 7000 portfolio snapshots loaded, and the
  chart's reads returned the same 730 or 731 rows on both sides.
- Review: read by the author of the change after `experimental` was merged
  into the branch; no independent review, for a change of about a hundred
  lines with a test that sets the new read against the old one. The fault
  above was found by measuring, not by reading.
- Known issues: none.
- Verdict: retained. The gain is small and confined to the chart: 22 ms of
  background work less each time it reloads, more for longer ranges. No
  standard row improved and none got worse.

### 93: Size the in-memory price history arrays to fit

- What: the app keeps each symbol's price history in memory as one array,
  which `thinnedPriceHistory` built a point at a time. An array that grows
  that way doubles each time it fills, so each one ended with room for far
  more points than it held: in the benchmark's store, a 384 KB block for
  3181 points that need 224 KB. The thinning now reserves its room once and,
  if it dropped more than an eighth of what it reserved, copies the result
  into an array of the right size.

  A fitted array is full, and a full array doubles at the next append. Each
  held symbol gains a point with every recorded price, so the fit would
  have been undone at the first one. New prices are therefore added through
  `appendToPriceHistory`, which makes room for 256 more points (18 KB) when
  a series is full instead of doubling it. The branch as it was carried over
  did not have this part; it was added before anything was measured.

  The points kept and their order are the same.
- Merged: 2026-11-12, squash commit `c4f4cff`
- Benchmark: before `f0fdcc3`, after `a18eda4`, six launches a side in turns
  on 2026-11-12 from 14:31 to 15:04 UTC, macOS 27.2.1, mains power, all
  twelve launches with the screen unlocked and the display awake. Named in
  advance: the memory held by the price history arrays, read from each
  launch's heap listing, expected to fall from 8.69 MB to about 5.2 MB; of
  the standard rows, the idle memory the app holds allocated expected about
  3.5 MB lower and idle memory possibly lower by a similar amount; no other
  row expected to move. The Mac was busy with other work (load average 7.1
  at the start, after waiting 60 s for it to fall below 8).

  | Change-specific row | Before | After | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Memory held by the price history arrays (69,982 points for 22 symbols) | 8.69 MB in all six launches | 5.25 MB in all six launches | -3.44 MB, -39.6% | lower: the same figure in every launch on each side |

  That row is the line for `_ContiguousArrayStorage<PriceSnapshot>` in the
  `heap` listing saved with every measured launch.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 94.6 (87.4 to 99.2) MB | 90.0 (87.7 to 94.0) MB | -4.6 MB, -4.9% | no measurable change (p = 0.240) |
  | Idle memory the app holds allocated | 53.2 (50.5 to 57.5) MB | 47.8 (46.7 to 50.9) MB | -5.4 MB, -10.1% | lower (p = 0.004) |
  | Peak memory, launch and history load | 241.2 (230.3 to 244.1) MB | 238.6 (227.1 to 245.8) MB | -2.6 MB, -1.1% | no measurable change (p = 0.818) |
  | Idle memory growth across the window | 0.0 (-0.8 to 0.1) MB | 0.0 (-4.7 to 0.0) MB | +0.0 MB | no measurable change (p = 0.273) |
  | Idle CPU | 0.094 (0.088 to 0.103) s/min | 0.099 (0.090 to 0.170) s/min | +0.005 s/min, +5.3% | no measurable change (p = 0.240) |
  | Idle CPU wake-ups | 28 (27 to 31) /min | 31 (22 to 39) /min | +3 /min, +10.7% | no measurable change (p = 0.452) |
  | Idle CPU power | 4.53 (4.22 to 4.65) mW | 4.59 (3.65 to 5.26) mW | +0.06 mW, +1.4% | no measurable change (p = 0.390) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 1.00 (0.55 to 1.57) s | 1.19 (0.68 to 1.88) s | +0.19 s, +18.5% | no measurable change (p = 0.589) |
  | Launch to history loaded | 0.99 (0.65 to 1.48) s | 1.18 (0.81 to 1.88) s | +0.19 s, +19.2% | no measurable change (p = 0.420) |
  | CPU from launch to the idle window | 2.05 (1.86 to 2.13) s | 2.29 (1.98 to 2.65) s | +0.24 s, +11.7% | no measurable change (p = 0.180) |
  | CPU energy from launch to the idle window | 6.13 (4.87 to 6.40) J | 5.93 (5.14 to 6.56) J | -0.21 J, -3.3% | no measurable change (p = 0.937) |
  | Python helper start to ready, no network | 0.33 (0.30 to 0.66) s | 0.33 (0.31 to 0.65) s | +0.00 s, +0.0% | no measurable change (p = 1.000) |
  | Python helper start, CPU | 0.32 (0.30 to 0.42) s | 0.32 (0.31 to 0.41) s | +0.00 s, +0.0% | no measurable change (p = 0.749) |
  | Python helper memory once started | 71.0 (70.9 to 71.2) MB | 71.0 (70.9 to 71.2) MB | +0.0 MB, +0.0% | no measurable change (p = 0.866) |

  The arrays fell as predicted. The idle memory the app holds allocated is
  lower, by 5.4 MB between the medians. Only 3.44 MB of that is this change:
  between two launches of the same build in this run, untyped allocations
  alone differed by 5.9 MB, and that is the spread of the row. Idle memory
  as a whole came out 4.6 MB lower, which is not distinguishable from no
  change (p = 0.240).

  The launch rows did not change. The Mac slowed down over the half hour,
  for both builds alike: the first window took 0.55 to 0.79 s in the first
  three "before" launches and 1.21 to 1.57 s in the last three; the six
  "after" launches, run between them, took 0.68 to 1.88 s. Measuring in
  turns is what keeps that drift out of the verdict.

  Not measured in the running app: growth by a step when prices are
  recorded. The benchmark has no market data, so nothing is appended. It is
  checked by a test instead, which is a count and not a timing: a fitted
  series of 3000 points given 1000 more never has room for more than 1000
  spare, and with the old behaviour it had room for 3185 once it had
  doubled.
- Testing: 705 XCTest tests with 0 failures (two new), 66 Python helper
  tests and 75 script tests pass, and `checks`, `docs-check` and
  `build-release` pass, all at `a18eda4`. Both new tests fail when the old
  behaviour is put back (5460 points of room for 3000 kept) and pass with
  the change. Every measured launch on both sides logged the same 22
  symbols with 69,982 points in memory and the same 7000 portfolio snapshots.
- Review: read by the author of the change after `experimental` was merged
  into the branch, together with every place that assigns or appends to a
  price series. That reading found the doubling at the first append. No
  independent review, for about twenty lines of app code with tests that
  count capacity directly.
- Known issues: none in this change. One thing seen and left alone is
  recorded as plan item 11.
- Verdict: retained, for 3.44 MB less allocated memory at idle with nothing
  given up.

### 94: Refuse to package an app built with test-coverage counters

- What: `script/package_release.sh` stops with "Refusing to package: the
  app was built with test-coverage instrumentation." when the executable it
  is about to sign carries coverage counters. It reads the executable
  itself (`size -m`, a section named `__llvm_prf…`) straight after the app
  is staged, before anything is signed or written to the output folder.
  Stockbar 3.7.0 was released with those counters built in. Pull request 85
  removed the cause, and nothing else in the release path would notice it
  coming back. Two new script tests package a stand-in app, one compiled
  with the coverage flags and one without, and two sentences in
  `Docs/Development.md` name the refusal.

  The check was on the carried-over branch beside pull request 85's scheme
  change. It came off because it changes the release packaging step, and
  waited for a decision from 2026-11-12. The owner asked for it to be
  merged on 2026-11-13. `experimental` had moved by five pull requests in
  between and was merged into the branch; nothing conflicted.
- Merged: 2026-11-13, squash commit `3cf549b`. The merge published
  experimental build 370.0.15 as the prerelease `experimental-370.0.15`.
  Checked after it: the feed's signature and the archive's signature are
  valid, the archive's length matches the feed, the unpacked app is build
  370.0.15 of 3.7.0, its code signature verifies and its executable has no
  `__llvm_prf` section. That release run was the check's first run in
  GitHub Actions, and it let the build through. `main`, `testing` and the
  stable and testing feed did not move.
- Benchmark: not run. No file that goes into the app differs between
  `7ed5e85` and this branch (nothing under `Stockbar/`, `StockbarTests/`,
  `PythonTests/` or `Stockbar.xcodeproj`), so before and after are the same
  app and all fifteen rows are "not measured". The one cost the change adds
  is to packaging: `size -m` on the 18 MB Release executable took 0.01 s in
  each of five runs, timed for the first version of this pull request on
  2026-11-12.
- Testing, on the branch with `experimental` at `7ed5e85` merged in:
  91 script tests pass, two of them new. 724 XCTest tests
  pass with 0 failures and 66 Python helper tests pass, though no
  file they build changes. `checks`, `docs-check` and `build-release` pass.
  One full packaging run, `package_release.sh --build 0.0.1` into a scratch
  folder, built the Release configuration, signed it ad hoc, zipped it and
  started the packaged app, and ended without error.

  From the first version, on 2026-11-12: packaging the saved benchmark
  build of the baseline `47c1bda`, whose sources are those of release 3.7.0
  and whose executable has seven `__llvm_prf` sections, was refused with
  the message and exit code 1, and nothing was written. Packaging the saved
  build of `bd56486`, the commit of pull request 85, succeeded. The new
  test fails against the script without the check.

  The check has not yet run in GitHub Actions. The release workflow's
  build of this merge is its first run there. The executable of the
  published experimental build 370.0.14 has no `__llvm_prf` section, so
  that build is not expected to be refused.
- Known issues:
  - It has to stay with pull request 85's scheme change. With the old
    scheme every Release build is instrumented and would be refused. A
    promotion of `experimental` as a whole carries both.
  - Packaging has a new way to stop. If `size` cannot read the executable,
    because it is missing or is not a Mach-O file, the script stops at this
    check with the error `size` prints.
  - The check goes by section name. Instrumentation that named its
    sections differently would pass. Only the app's own executable is
    read, not the Sparkle framework's, which Stockbar does not build.
  - The new tests need macOS and its developer tools, and are skipped
    without them.
- Verdict: retained. Nine lines and a hundredth of a second for each
  package, against a fault that has shipped once and that nothing else
  detects.

### 95: Keep the popover chart's line from doubling back at a gap in time

- What: a bug fix. The owner reported it from a second Mac running 3.7.0: in
  the popover's chart of the last 24 hours, the line swung back to the left
  just before the night between two trading sessions and overshot just after
  it.

  The two popover charts, the portfolio's and each stock's, smooth their
  line with a curve whose direction at each point comes from the points
  either side of it. Prices five minutes apart sit about a pixel apart, and
  the first price of the next morning sits more than a hundred pixels
  further on. That far neighbour set a pull over twenty pixels long on a
  piece of curve one pixel wide, so the curve ran backwards before the gap
  and past its end point after it.

  The pull is now shortened, keeping its direction, to reach no further
  than a third of the way across its own piece of the line. The line then
  only ever moves forward in time.

  Behaviour change, deliberate: evenly spaced points give a pull of exactly
  a third, so their curves are the same as before, to the last digit. Where
  a piece of the line sits beside a wider one, around a night or a weekend,
  its curve is tighter at that end. Nothing else changes: the same points,
  the same scale, the same hover. The main window's charts are drawn by
  Swift Charts and never had the fault.
- Merged: 2026-11-12, squash commit `c3c21ec`
- Benchmark: before `c4f4cff`, after `4ba6ea8`, measured twice on
  2026-11-12, each time six launches a side in turns on macOS 27.2.1 and
  mains power, all twelve launches with the screen unlocked and the display
  awake. Named in advance: no row expected to move, because the benchmark
  opens the main window and never the popover.

  That reason was checked, and it holds. A temporary copy of the branch,
  not committed, left an empty file behind whenever the popover chart was
  built, drew, or worked out a curve. Built and started the way the
  benchmark starts the app, for a warm-up launch and a measured one, it
  left none of the three files, and its binary did hold the three file
  names. The code this pull request changes does not run in the benchmark,
  so no row below can have moved because of what that code does.

  | Change-specific row | Before | After | Change | How measured |
  | --- | --- | --- | --- | --- |
  | Furthest the drawn line moves back to the left: a made-up day of two sessions with a night between, 158 points on a chart 300 points wide | 9.4 points | 0.0 points | -9.4 points | Each piece of the curve stepped through at 200 positions; exact arithmetic, one run |
  | Working out the control points of that whole line | 0.26 (0.24 to 0.38) µs | 0.51 (0.49 to 0.61) µs | +0.25 µs | A copy of both formulas compiled with `-O`, 25 timings of 2,000 lines each, in turns; a second run gave 0.26 and 0.50 |

  That is a quarter of a microsecond more for each line drawn, where one
  frame at 60 a second is 16,667 µs.

  First run, 16:06 to 16:40 UTC. The load average was 7.3 at the start,
  after waiting 80 s for it to fall below 8.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 99.8 (99.2 to 102.1) MB | 96.5 (92.4 to 102.6) MB | -3.2 MB, -3.2% | no measurable change (p = 0.457) |
  | Idle memory the app holds allocated | 54.6 (53.8 to 55.6) MB | 52.0 (48.3 to 55.3) MB | -2.6 MB, -4.7% | no measurable change (p = 0.292) |
  | Peak memory, launch and history load | 244.4 (241.5 to 251.6) MB | 243.9 (234.4 to 250.8) MB | -0.5 MB, -0.2% | no measurable change (p = 0.818) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.5) MB | 0.0 (0.0 to 0.1) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.085 (0.081 to 0.087) s/min | 0.089 (0.075 to 0.100) s/min | +0.005 s/min, +5.9% | no measurable change (p = 0.563) |
  | Idle CPU wake-ups | 27 (24 to 31) /min | 31 (24 to 43) /min | +4 /min, +14.8% | no measurable change (p = 0.121) |
  | Idle CPU power | 4.09 (3.97 to 4.22) mW | 4.33 (4.17 to 4.51) mW | +0.25 mW, +6.0% | higher (p = 0.006) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.47 (0.45 to 0.52) s | 0.63 (0.49 to 1.16) s | +0.16 s, +34.0% | higher (p = 0.004) |
  | Launch to history loaded | 0.58 (0.57 to 0.62) s | 0.77 (0.57 to 1.15) s | +0.19 s, +31.6% | no measurable change (p = 0.087) |
  | CPU from launch to the idle window | 1.89 (1.87 to 1.99) s | 1.96 (1.89 to 2.24) s | +0.07 s, +3.7% | no measurable change (p = 0.089) |
  | CPU energy from launch to the idle window | 6.21 (5.80 to 6.29) J | 6.07 (4.39 to 6.44) J | -0.14 J, -2.3% | no measurable change (p = 0.699) |
  | Python helper start to ready, no network | 0.36 (0.31 to 0.70) s | 0.29 (0.28 to 0.59) s | -0.07 s, -19.2% | no measurable change (p = 0.167) |
  | Python helper start, CPU | 0.34 (0.31 to 0.43) s | 0.29 (0.28 to 0.36) s | -0.05 s, -14.7% | no measurable change (p = 0.063) |
  | Python helper memory once started | 71.0 (70.9 to 71.2) MB | 71.0 (70.9 to 71.0) MB | -0.1 MB, -0.1% | no measurable change (p = 0.297) |

  Repeat, 17:34 to 18:06 UTC. The Mac had been asleep. It woke at 17:27 UTC
  on battery and was on mains by 17:32; the run waited until three checks
  in a row found it on mains with a load average below 8. The load average
  over the five minutes before the start was 28.6, and the battery charged
  from 47 to 68 percent while the run went on.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 102.6 (101.8 to 103.6) MB | 101.6 (101.3 to 102.5) MB | -1.0 MB, -1.0% | possibly lower (p = 0.013) |
  | Idle memory the app holds allocated | 57.0 (56.4 to 57.4) MB | 56.3 (55.2 to 57.0) MB | -0.8 MB, -1.3% | no measurable change (p = 0.071) |
  | Peak memory, launch and history load | 249.3 (247.5 to 251.4) MB | 248.9 (245.1 to 261.0) MB | -0.4 MB, -0.2% | no measurable change (p = 0.556) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.1) MB | 0.0 (0.0 to 0.0) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.190 (0.144 to 0.194) s/min | 0.198 (0.193 to 0.205) s/min | +0.009 s/min, +4.5% | higher (p = 0.006) |
  | Idle CPU wake-ups | 25 (24 to 27) /min | 24 (23 to 25) /min | -1 /min, -4.0% | possibly lower (p = 0.037) |
  | Idle CPU power | 3.69 (3.56 to 4.07) mW | 3.70 (3.61 to 4.27) mW | +0.01 mW, +0.3% | no measurable change (p = 0.665) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.55 (0.54 to 0.61) s | 0.59 (0.53 to 0.76) s | +0.04 s, +7.3% | no measurable change (p = 0.281) |
  | Launch to history loaded | 0.58 (0.56 to 0.72) s | 0.66 (0.55 to 0.74) s | +0.08 s, +12.8% | no measurable change (p = 0.561) |
  | CPU from launch to the idle window | 2.08 (2.04 to 2.13) s | 2.12 (2.07 to 2.24) s | +0.04 s, +1.9% | no measurable change (p = 0.130) |
  | CPU energy from launch to the idle window | 6.07 (5.98 to 6.36) J | 6.36 (6.30 to 6.54) J | +0.28 J, +4.6% | possibly higher (p = 0.017) |
  | Python helper start to ready, no network | 0.29 (0.27 to 0.56) s | 0.31 (0.27 to 0.87) s | +0.01 s, +3.4% | no measurable change (p = 0.983) |
  | Python helper start, CPU | 0.29 (0.27 to 0.36) s | 0.30 (0.27 to 0.38) s | +0.01 s, +3.4% | no measurable change (p = 0.814) |
  | Python helper memory once started | 71.0 (70.9 to 71.1) MB | 71.0 (70.9 to 71.2) MB | +0.0 MB, +0.1% | no measurable change (p = 0.374) |

  Three rows were marked "higher" across the two runs, none of them in
  both. Each follows a step in the Mac's state part of the way through a
  run:

  - Launch to first window, first run. The six launches of this branch
    were measured in two rounds of three. The first round took 0.70, 1.16
    and 1.04 s and the second 0.56, 0.56 and 0.49 s, against 0.45 to 0.52 s
    for `experimental` either side of them. In the repeat the two sides
    took 0.54 to 0.61 s and 0.53 to 0.76 s: no measurable change
    (p = 0.281).
  - Idle CPU power, first run: 4.33 mW against 4.09 mW. In the repeat, 3.70
    mW against 3.69 mW: no measurable change (p = 0.665).
  - Idle CPU, repeat. The first two launches of the run, both of
    `experimental`, used 0.150 and 0.144 s/min. The other ten used 0.189 to
    0.205 s/min: `experimental` 0.189 to 0.194 in four launches and this
    branch 0.193 to 0.205 in six. The verdict rests on those first two
    launches. In the first run the row was 0.085 against 0.089 s/min, no
    measurable change (p = 0.563). Every launch of the repeat, on both
    sides, used about twice the CPU that the same two builds had used
    ninety minutes earlier on the same workload, so that difference is the
    Mac, which had just woken and was charging.

  The three rows marked "possibly" in the repeat (idle memory 1.0 MB lower,
  wake-ups 1 a minute lower, launch energy 0.28 J higher) were "no
  measurable change" in the first run, two of them with the opposite sign.

  So this pull request made no measurable change. What the two runs do
  show is a limit of the benchmark: its verdict treats twelve launches as
  twelve independent measurements, and when the Mac changes state in a
  step during a run, launches measured together share that state. A row
  that moves without having been named in advance is therefore repeated
  before it counts, whatever its p value. "How this branch works" now says
  so.

  Not measured: the popover's drawing time in the running app, and energy
  while the popover is open. The benchmark has no step that opens the
  popover, and the arithmetic in the first table is the only part of the
  drawing that changed.
- Testing: 710 XCTest tests with 0 failures (five new), 66 Python helper
  tests and 75 script tests pass, and `checks`, `docs-check` and
  `build-release` pass, all at `4ba6ea8`. With the old formula put back,
  four of the five new tests fail: the line moves back, a pull reaches
  outside its own piece, the pull before the night is 22.8 points long
  where a third of the piece is 0.33, and two points at the same time are
  not joined by a straight line. The fifth, that evenly spaced points keep
  the curve they had, passes either way, as it should.

  The app's own chart view was also drawn to a picture by a temporary test,
  not committed, for a made-up day of two sessions: with the old formula it
  shows the hook before the night and the overshoot after it, as in the
  report, and with the fix neither. Six other made-up shapes were drawn
  both ways from a copy of the two formulas. Evenly spaced points and two
  points come out identical; daily closes with weekends differ by control
  points moved at most 2.3 points, with no visible change of shape; six
  unevenly spaced points, three sessions with two nights, and three points
  each lose a backward movement of 15.1, 7.3 and 1.3 points.

  Not checked on real data: the Mac that showed the fault runs the released
  3.7.0, and the fix reaches an installed app only through a release.
- Review: read by the author of the change, together with the arithmetic
  for why the line cannot turn back (a piece of curve whose two control
  points lie in order between its end points only moves forward). No
  independent review, for about twenty lines of drawing arithmetic whose
  result was looked at directly in seven shapes.
- Known issues: none in the change. The benchmark marked rows for code it
  never ran; see the record above.
- Verdict: retained. It is a correctness fix, the benchmark does not run
  its code, and no row moved in both of its two runs.

### 96: Record milestone 1: every merged change measured against the baseline

- What: the [Milestone 1](#milestone-1-2026-11-12) section above, the
  measured results of plan items 8, 9, 11 and 12, plan item 13, four rows
  in "Tried and rejected", and the merge line of pull request 95. Only this
  file changes.
- Merged: 2026-11-12, squash commit `dd56915`
- Benchmark: no before/after run. No file that goes into the app changes
  (nothing under `Stockbar/`, `StockbarTests/` or `Stockbar.xcodeproj`), so
  before, `c3c21ec`, and after build the same app. What this pull request
  records are the milestone's own measurements: the comparison of `47c1bda`
  with `c4f4cff` and the two soak runs, all under Milestone 1.
- Testing: 710 XCTest tests with 0 failures, 66 Python helper tests and 75
  script tests pass, and `checks`, `docs-check` and `build-release` pass, on
  this pull request's branch.
- Review: read by its author, with each figure checked again against the
  result files it comes from. No independent review, for a record of
  measurements that changes no code.
- Known issues: two things in the soak runs are not explained. The baseline
  held 6.8 MB more allocated than in its soak of the night before, and both
  runs used about four times the CPU of that earlier soak. See the notes
  under the soak's table.
- Verdict: retained.

### 97: Add an Experimental update channel that follows the experimental branch

- What: a feature the owner asked for, not an optimisation. **Settings →
  General → Updates** offers a third update channel, Experimental, beside
  Stable and Testing. Someone who chooses it is offered every build of the
  `experimental` branch.

  In the app, `UpdateChannel` gains `experimental`. That channel reads a
  second update feed, whose address is the new `StockbarExperimentalFeedURL`
  key of `Info.plist`; the updater's delegate hands it to Sparkle each time
  Sparkle checks. Stable and Testing read the feed they always have. In a
  test or acceptance run the second feed is read only when it is served
  from this Mac, the rule the first feed already follows.

  In the release workflow, a push to `experimental` is built, signed and
  published the way a push to `testing` is: as a prerelease, tagged
  `experimental-<build>`, and listed in a feed of its own, `appcast.xml` on
  a new `appcast-experimental` branch. A branch whose name starts
  `release-test/experimental` is a dry run of such a build and publishes
  nothing.

  The build number is `<base>.<A>.<M>`: the build of the last version tag,
  then the number of commits since that tag that `testing` also has, then
  the number it does not have. The head of `experimental` as this pull
  request was written would be 370.0.11. An experimental build therefore
  sorts above the testing build it contains and below the next one. The
  number depends on where `testing` is when the build is made, so only the
  newest commit of `experimental` is built. When `experimental` is moved
  onto a tagged commit, that commit is published to the channel as
  `<base>.0.0`, which Sparkle treats as the release itself; that is how a
  release reaches the channel.

  The builds have a feed of their own because the copy of
  `Scripts/release_feed.py` on `testing` and `main` refuses to rewrite a
  feed that holds a channel it does not know. In a shared feed the first
  experimental build would have stopped testing builds and releases from
  being published. The script now refuses to list the two kinds together,
  in either direction.

  Behaviour changes for the builds that already exist. All are in the step
  that removes superseded prereleases, which both kinds of build now share,
  except the last:

  - Given an empty feed, or the other kind's feed, the step now fails. It
    used to remove every `testing-` prerelease.
  - It removes only prereleases tagged `testing-<build number>`. A
    `testing-` tag that does not end in a build number is left alone.
  - A tag that spells a listed build number differently (`360.04` for
    `360.4`) is kept. It used to be removed.
  - The release notes of a testing build look for the previous build among
    tags matching `testing-[0-9]*` where they matched `testing-*`.

  Everything else about a testing build, a release and an ordinary dry run
  is as before: the same build numbers, tags, titles and feed, checked by
  the review on made-up histories and feeds (see Review).
- Merged: 2026-11-12, squash commit `ec22bc3`, on the owner's word. The
  merge was the first push the changed workflow built. Its run published
  the prerelease `experimental-370.0.12` and created the
  `appcast-experimental` branch. Checked afterwards: the feed's signature
  and the archive's signature both verify against the `SUPublicEDKey` in
  `Info.plist`; the archive's length matches the feed; the unpacked app
  reports build 370.0.12 of version 3.7.0, carries both feed addresses, has
  no coverage sections and passes `codesign --verify --deep --strict`.
  `main`, `testing` and the `appcast` branch did not move.
- Benchmark: before `dd56915`, after `fab1363`, six launches a side in turns
  on 2026-11-12, 21:10 to 21:43 UTC, on macOS 27.2.1 and mains power, all
  twelve launches with the screen unlocked and the display awake. Named in
  advance: no row expected to move. The benchmark runs the app isolated,
  where the updater does not start, so the delegate that chooses the feed
  is never created. The only new code a launch runs is the read of one more
  value from the bundle's `Info.plist`.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 101.8 (100.5 to 102.4) MB | 102.8 (100.4 to 103.5) MB | +1.1 MB, +1.1% | no measurable change (p = 0.141) |
  | Idle memory the app holds allocated | 57.1 (55.5 to 57.9) MB | 57.3 (55.1 to 57.9) MB | +0.1 MB, +0.3% | no measurable change (p = 0.981) |
  | Peak memory, launch and history load | 251.2 (243.1 to 256.8) MB | 255.9 (248.0 to 260.8) MB | +4.8 MB, +1.9% | no measurable change (p = 0.387) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.0) MB | 0.0 (0.0 to 0.2) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.204 (0.174 to 0.210) s/min | 0.197 (0.189 to 0.210) s/min | -0.007 s/min, -3.4% | no measurable change (p = 0.329) |
  | Idle CPU wake-ups | 24 (23 to 25) /min | 26 (24 to 29) /min | +2 /min, +8.3% | possibly higher (p = 0.022) |
  | Idle CPU power | 3.54 (3.42 to 3.82) mW | 3.84 (3.50 to 4.54) mW | +0.30 mW, +8.5% | no measurable change (p = 0.104) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.55 (0.50 to 0.65) s | 0.55 (0.51 to 0.60) s | -0.01 s, -0.9% | no measurable change (p = 0.846) |
  | Launch to history loaded | 0.56 (0.54 to 0.79) s | 0.56 (0.53 to 0.57) s | -0.00 s, -0.9% | no measurable change (p = 0.567) |
  | CPU from launch to the idle window | 2.09 (2.01 to 2.35) s | 2.04 (1.98 to 2.11) s | -0.05 s, -2.6% | no measurable change (p = 0.290) |
  | CPU energy from launch to the idle window | 6.28 (6.14 to 6.44) J | 6.13 (5.98 to 6.40) J | -0.14 J, -2.2% | no measurable change (p = 0.193) |
  | Python helper start to ready, no network | 0.28 (0.28 to 0.54) s | 0.29 (0.28 to 0.47) s | +0.01 s, +1.8% | no measurable change (p = 0.924) |
  | Python helper start, CPU | 0.28 (0.27 to 0.34) s | 0.28 (0.27 to 0.32) s | +0.01 s, +1.8% | no measurable change (p = 0.680) |
  | Python helper memory once started | 71.0 (70.9 to 71.0) MB | 71.0 (70.9 to 71.0) MB | +0.0 MB, +0.1% | no measurable change (p = 1.000) |

  Fourteen rows show no measurable change. Idle CPU wake-ups came out
  "possibly higher", 26 a minute against 24 (p = 0.022). Nothing this pull
  request adds runs while the benchmark's app idles, and a "possibly" row
  needs a repeat before it counts either way.

  Repeat, 21:46 to 22:19 UTC, with the same two commits under the same
  conditions:

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 100.2 (97.9 to 103.7) MB | 99.1 (98.1 to 100.4) MB | -1.1 MB, -1.0% | no measurable change (p = 0.554) |
  | Idle memory the app holds allocated | 54.9 (45.6 to 57.5) MB | 54.8 (54.3 to 55.5) MB | -0.1 MB, -0.1% | no measurable change (p = 0.974) |
  | Peak memory, launch and history load | 245.6 (240.1 to 256.1) MB | 244.8 (243.3 to 245.7) MB | -0.8 MB, -0.3% | no measurable change (p = 0.777) |
  | Idle memory growth across the window | 0.0 (-0.0 to -0.0) MB | 0.0 (0.0 to 0.0) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.079 (0.070 to 0.191) s/min | 0.079 (0.068 to 0.084) s/min | +0.001 s/min, +0.6% | no measurable change (p = 0.630) |
  | Idle CPU wake-ups | 26 (23 to 28) /min | 24 (24 to 25) /min | -2 /min, -7.7% | possibly lower (p = 0.050) |
  | Idle CPU power | 4.21 (4.08 to 4.50) mW | 4.09 (3.95 to 4.41) mW | -0.12 mW, -2.9% | no measurable change (p = 0.329) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.55 (0.51 to 0.55) s | 0.55 (0.53 to 0.56) s | +0.00 s, +0.0% | no measurable change (p = 0.387) |
  | Launch to history loaded | 0.59 (0.54 to 0.62) s | 0.59 (0.57 to 0.61) s | +0.01 s, +0.8% | no measurable change (p = 0.524) |
  | CPU from launch to the idle window | 1.97 (1.81 to 2.12) s | 1.82 (1.81 to 1.87) s | -0.15 s, -7.6% | possibly lower (p = 0.043) |
  | CPU energy from launch to the idle window | 6.19 (5.97 to 6.46) J | 5.97 (5.90 to 6.12) J | -0.21 J, -3.4% | possibly lower (p = 0.026) |
  | Python helper start to ready, no network | 0.28 (0.28 to 0.54) s | 0.28 (0.28 to 0.46) s | +0.00 s, +0.0% | no measurable change (p = 0.697) |
  | Python helper start, CPU | 0.28 (0.28 to 0.34) s | 0.28 (0.28 to 0.32) s | +0.00 s, +0.0% | no measurable change (p = 0.697) |
  | Python helper memory once started | 71.0 (71.0 to 71.4) MB | 71.0 (70.9 to 71.0) MB | +0.0 MB, +0.0% | no measurable change (p = 0.273) |

  In the repeat idle CPU wake-ups came out "possibly lower", 24 a minute
  against 26 (p = 0.050), the opposite of the first run. CPU and CPU energy
  from launch to the idle window came out "possibly lower" as well (p =
  0.043 and 0.026); in the first run both were "no measurable change" (p =
  0.290 and 0.193). No row moved in both runs, so this pull request made no
  measurable change, as named in advance. The first run's launches used
  about two and a half times the idle CPU of the repeat's, 0.20 against
  0.08 s/min on both sides, which is the Mac's state and not the build.

  An earlier attempt, started at 20:43 UTC, was cut short after six of its
  twelve launches when the tool that had started it restarted. Its launches
  are not used.

  Not measured: an update check on the Experimental channel. It is the same
  single request the other channels make, to a different address, and the
  benchmark runs with the updater off. The 30-minute soak is deferred to
  the next milestone.
- Testing: 717 XCTest tests with 0 failures (seven new), 66 Python helper
  tests and 89 script tests (fourteen new) pass, and `checks`, `docs-check`
  and `build-release` pass, all at `fab1363`.

  The new Swift tests cover which feed each channel reads, the rule for
  isolated runs, that the updater's delegate answers the Objective-C method
  Sparkle asks for the feed, that both shipped feed addresses are the
  branches the feed script publishes to, and that Sparkle's own comparison
  puts build numbers in the order the feed script's tests sort them. The new
  script tests cover the numbering, the skip of a commit the branch has
  moved on from, the tagged commit, the separate feeds and the removal of
  superseded builds.

  Tried end to end on this Mac at the first commit, `0f3a2e5`, with a
  scratch copy of the Release build under another bundle identifier, two
  feeds served from this Mac and a throwaway signing key. The project's own
  scripts signed four builds and wrote both feeds. Launched once on each
  channel, the copy asked for the ordinary feed on Stable and Testing and
  for the experimental feed on Experimental. In its Settings window the
  channel picker offered all three; running build 370.0.1, it was offered
  370.0.2 on Experimental, 370.1 on Testing and nothing on Stable, and a
  change of channel made it check again without a restart. The trial
  stopped at the offer: no update was installed from an experimental feed.
  `script/package_release.sh` packaged a build numbered 370.0.1, and its
  start check passed. The installed app was not touched, and everything the
  trial left behind was removed.

  The workflow's steps were run on this Mac for a push to `experimental`,
  to `testing`, to both kinds of dry-run branch and for a version tag, and
  again in throwaway repositories after the review's fixes: a branch moved
  onto a tagged commit, a commit the branch has moved on from, a second
  branch whose name ends the same way, and a version tag that `testing`
  does not have yet.

  Not tested: the workflow on GitHub. It cannot run there until this is
  merged or a `release-test/experimental…` branch is pushed, and both wait
  for the owner. Signing with the real update key, creating the
  `appcast-experimental` branch and publishing a prerelease happen for the
  first time in that first run.
- Review: one independent review by Opus of the first commit, by a reviewer
  that had not seen the implementation. It found no blocking defect, one
  fault worth fixing and several smaller points. Each was confirmed before
  it was acted on, and the fixes are the second commit, `fab1363`:

  - A push that moves `experimental` onto a tagged commit was skipped, as it
    is on `testing`, so a release would never have been offered on the
    channel. It is now published there as `<base>.0.0`.
  - The tests and the development notes said 360.9.0 sorts above 360.9.
    Sparkle's own comparison, run against the project's copy of Sparkle,
    calls them equal. The tests and notes are corrected, and a Swift test
    now asks Sparkle for the order.
  - The check that a commit is still the newest of its branch matched
    branch names by their ending. It could only have skipped a build
    wrongly, never published one. It now matches the whole name.
  - "How this branch works" in this file said that no workflow runs for
    `experimental`. Corrected below.

  The review also confirmed, on throwaway repositories and 300 made-up
  feeds, that the plan for a testing build, a release and an ordinary dry
  run is unchanged apart from one new line of output, that the ordinary
  feed is written byte for byte as before, and that experimental build
  numbers only rise as the two branches move, short of a force-push.
- Known issues, all consequences of the design:
  - The Experimental channel is offered experimental builds only. A release
    or a testing build reaches it once `experimental` contains it.
  - After a new version tag, a push to `experimental` fails in the
    workflow's first step until the tag is in the branch's history. The
    same rule already holds for `testing`.
  - After `experimental` is merged into `testing` with a merge commit, its
    builds are numbered below the testing build that merge made, until
    `testing` is brought back into `experimental`.
  - Every push to `experimental` publishes a build, including a merge that
    changes only this file.
  - The released 3.7.0 has no Experimental option. The first experimental
    build has to be installed by hand from its prerelease page; from then
    on the channel updates itself.
  - A build from before this change that finds the Experimental channel
    stored reads it as Stable. That can only follow a downgrade by hand,
    and the choice comes back with the next build that knows the channel.
  - Pre-existing, not changed here: a release run and a testing run are not
    kept apart, so a release's clean-up could remove a testing prerelease
    created at the same moment.
- Verdict: retained.

### 98: Add a setting that turns off the rolling digits

- What: a switch, **Settings → Advanced → Memory → Roll Digits When
  Figures Change**, on unless turned off. On, figures roll to a new value
  as they always have. Off, they change without rolling, and the bitmaps
  of digits that the system caches while a figure rolls are not made. The
  owner asked for it on 2026-11-12, after
  [Milestone 1](#milestone-1-2026-11-12) traced about 6 MB of idle memory
  to that cache.

  The ten figures that rolled now ask for it with one modifier,
  `stockbarRollingDigits()`, which leaves the transition out when the
  setting is off. The three SwiftUI roots that AppKit hosts (the main
  window, the popover of a symbol and the popover of the portfolio) each
  read the setting once and pass it down. `Scripts/validate_invariants.sh`
  now refuses the transition written anywhere else, so a figure added
  later cannot ignore the switch unnoticed. The setting,
  `figures.rollingDigits`, is stored with the app's other defaults and
  travels with a settings export. The user guide and the architecture note
  describe it.
- Merged: 2026-11-13, squash commit `7ed5e85`. The merge published the
  prerelease `experimental-370.0.14`. Checked afterwards: the feed's
  signature and the archive's signature both verify against the
  `SUPublicEDKey` in `Info.plist`; the archive's length matches the feed;
  the unpacked app reports build 370.0.14 of version 3.7.0, holds the new
  setting's key and passes `codesign --verify --deep --strict`. `main`,
  `testing` and the `appcast` branch did not move.
- Benchmark: not run. The owner's instruction, given on 2026-11-12 at 23:46
  UTC, was "skip the benchmark on the digits toggle." All fifteen rows of
  the standard set are therefore not measured for this pull request, and
  none is carried over from another run. It is the one change on the branch
  merged without the standard comparison. If a later comparison or
  milestone shows a regression, this pull request is among those to bisect.

  Expected, and theoretical: with the switch on, which is the default, no
  row moves, because the same transition reaches the same figures. What
  differs with it on is that each figure passes through a modifier that
  reads one value from the environment and chooses between two branches.
- Glyph cache with the switch off and on: the one thing measured. A Release
  build of the branch was started the way the benchmark starts it, on the
  made-up fixture with live providers off, with the system recording where
  each allocation is made (`MallocStackLogging=lite`), and read with `heap`
  60 seconds after its history had loaded. Four launches in turns on
  2026-11-13, 00:15 to 00:24 UTC. The setting was written to the launch's
  own settings file beforehand and read back from it afterwards.

  | Launch | Switch | Glyph bitmaps held | Blocks |
  | --- | --- | --- | --- |
  | 1 | off | 0.43 MB | 557 |
  | 2 | on | 9.85 MB | 4,722 |
  | 3 | off | 0.41 MB | 526 |
  | 4 | on | 9.35 MB | 4,509 |

  Counted as at Milestone 1: the blocks `heap` attributes to
  `CGGlyphBuilderLockBitmaps` and `CGGlyphBitmapCreate`. Off, the cache
  holds about what it held in the milestone's trial build without the
  transition (0.46 MB). On, it held about 3 MB more than the milestone's one launch
  (6.52 MB); why was not looked into. How much a launch caches varies with
  its timing (see Milestone 1), and the Mac was not quiet: the test suite,
  the check on screen and the download of pull request 86's build ran
  beside these launches. So these are what four launches held, not a
  constant, and the switch's description and the user guide say "6 to 10
  MB". The build measured had the description's earlier wording, "about 6
  MB"; the commit merged differs from it in that sentence, a comment and
  the user guide.

  Not measured: what the switch does to idle memory, which is a row of the
  comparison that was not run. In pull request 86's two runs idle memory
  rose and fell with the number of cached glyph blocks, so a saving of
  about the size of the cache is expected. It is theoretical until a
  comparison measures it. Also not measured: the cache after a popover has
  been opened or a refresh has rolled a figure.
- Testing: 724 XCTest tests with 0 failures. Two are new, in
  `RollingDigitsSettingTests`. One puts a figure in a real hosting view and
  reads the transition it ends up with: rolling with the setting unset, not
  rolling with it off, rolling again with it on. The other checks that the
  setting is on the settings export list. `checks`, which now includes the
  new invariant, and `build-release` pass on the commit merged, and so does
  `docs-check`. The invariant's pattern was tried on made-up lines and
  flags a direct use, one inside `StockbarDesign.swift` included. 66 Python
  helper tests and 89 script tests pass; they were run before the
  description's figure was corrected, which changed no Python.

  On screen: a trial copy of the Release build, on the made-up fixture with
  live providers off, was worked through by a Sonnet subagent. Settings →
  Advanced → Memory shows two switches. Their titles and descriptions as
  read from the accessibility tree match what is drawn, and nothing is cut
  off or overlapping in a window of 1464 by 860 points. The new switch read
  on. One press turned it off; no alert or sheet appeared, the helper's
  switch stayed as it was, and the Overview page showed its figures
  normally afterwards. The trial's settings file then held
  `figures.rollingDigits` as false. The check read the description when it
  said "about 6 MB"; the corrected sentence was not read on screen again.
  That figures visibly stop rolling was not watched: with providers off
  nothing changes a figure after launch. The test above and the cache
  measurement stand in for it.
- Review: one independent review by Opus, of the diff before this entry was
  written. It found no functional defect. It found that the switch's
  description, the user guide and the comments stated more than had been
  measured, about how much memory the rolling costs and when it comes
  back. It found that the test did not read what a figure actually does,
  and that nothing kept a figure added later from using the transition
  directly. All of that
  was corrected before the tests above were run: the wording, the test that
  reads a hosted figure's transition, and the invariant with its note in
  the architecture document.
- Known issues:
  - The standard benchmark was not run, as set out above.
  - Turning the switch off does not give back memory already cached. That
    may take a restart: at Milestone 1 the cache was still held after 30
    minutes.
  - Off takes away the roll, not every animation. Three figures animate
    their own change unless Reduce Motion is on, and with the switch off
    they change with SwiftUI's default transition.
  - Turning the switch rebuilds each figure once, because the modifier
    chooses between two branches. Nothing was seen of it on screen.
  - A SwiftUI root added later has to end its body with
    `stockbarRollingDigitsSetting()`, or its figures roll whatever the
    switch says. The architecture note says so; no check enforces it.
  - Importing settings that were exported by a build without the switch
    puts it back to on.
- Verdict: retained, as a switch that is on unless turned off. Nothing
  changes for anyone who leaves it alone.

### 101: Bring `testing` back into `experimental` and record the promotion

- What: merges `testing` at `2256b6c` into `experimental`, so that the
  merge commit of the promotion is in its history and its builds are
  numbered above testing build 370.16. Records the promotion and the
  comparison made after it in this log
  ([Promotion to `testing`](#promotion-to-testing-2026-11-13)), fills in
  pull request 94's merge, and adds three sentences to
  `Docs/Development.md` on how a promotion is made. The merge brings one
  commit, whose files are the ones `experimental` already had, so no file
  of the app, its tests or its scripts changes.
- Merged: 2026-11-13, merge commit `e43a8c0`, with a merge commit as
  planned: after a squash `2256b6c` would not be in the history of
  `experimental`, and its builds would stay numbered below 370.16. The
  merge published experimental build 370.16.2 as the prerelease
  `experimental-370.16.2`. Checked after it: the feed's signature and the
  archive's signature are valid, the archive's length matches the feed,
  the unpacked app is build 370.16.2 of 3.7.0, its code signature verifies
  and its executable has no `__llvm_prf` section. `main` and `testing` did
  not move.
- Benchmark: before, `3cf549b`, and after are the same app, so all fifteen
  rows are "not measured" for this pull request. The comparison of the
  baseline with the promoted commit was run for it and is under
  [Promotion to `testing`](#promotion-to-testing-2026-11-13).
- Testing: `docs-check` and `checks` pass on the branch. The tests were not
  run again here. The files they build are those of `2256b6c`, on which
  both CI jobs passed after the promotion.
- Known issues: none known. Each later promotion needs the same two steps,
  which `Docs/Development.md` now names.
- Verdict: retained.

### 102: Turn on Quit Python Helper When Idle by default

- What: the switch from pull request 86, **Settings → Advanced → Memory →
  Quit Python Helper When Idle**, is on unless turned off. A helper nobody
  is using quits about 90 seconds after its last request instead of 15
  minutes. The owner asked for it on 2026-11-13. Only a setting that was
  never changed takes the default, so a Mac where the switch was turned
  off keeps it off. `PythonWorkerPool.quitWhenIdleDefault` is the one
  default, read by the pool and by the Settings switch. The switch's
  description, the user guide and the architecture note describe both
  states and say it is on by default. A pool made without a timeout, which
  only tests do, still keeps its workers for 15 minutes.
- Merged: 2026-11-13, squash commit `267cf3b`. The merge published
  experimental build 370.16.3 as the prerelease `experimental-370.16.3`.
  Checked after it: the feed's signature and the archive's signature are
  valid, the archive's length matches the feed, the unpacked app is build
  370.16.3 of 3.7.0 and carries the new description, its code signature
  verifies and its executable has no `__llvm_prf` section. `main` and
  `testing` did not move.
- Benchmark: before `e43a8c0`, after `ea7aa22`, six launches a side in
  turns from 09:30 to 10:05 UTC on 2026-11-13, macOS 27.2.1 and mains
  power, all twelve launches with the screen unlocked and the display
  awake. The Mac had restarted at 09:03 UTC, and the load average was 15.9
  when the run started and 5.2 when it ended. Named in advance: no row
  expected to move. The benchmark never starts a helper through the pool
  (the helper was alive in none of the samples of any of the twelve
  launches), and its three helper rows start one directly. No row moved.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 96.2 (94.7 to 97.8) MB | 96.7 (89.4 to 99.5) MB | +0.5 MB, +0.6% | no measurable change (p = 0.818) |
  | Idle memory the app holds allocated | 51.5 (50.1 to 53.8) MB | 52.4 (51.4 to 53.6) MB | +0.9 MB, +1.6% | no measurable change (p = 0.271) |
  | Peak memory, launch and history load | 251.6 (240.1 to 255.9) MB | 255.8 (249.3 to 261.4) MB | +4.3 MB, +1.7% | no measurable change (p = 0.310) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.0) MB | 0.0 (0.0 to 0.0) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.080 (0.066 to 0.085) s/min | 0.081 (0.078 to 0.087) s/min | +0.001 s/min, +1.3% | no measurable change (p = 0.613) |
  | Idle CPU wake-ups | 26 (24 to 31) /min | 28 (25 to 43) /min | +2 /min, +7.8% | no measurable change (p = 0.323) |
  | Idle CPU power | 4.26 (4.16 to 4.70) mW | 4.17 (4.14 to 4.93) mW | -0.08 mW, -2.0% | no measurable change (p = 0.260) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.58 (0.53 to 0.60) s | 0.56 (0.54 to 1.35) s | -0.02 s, -3.4% | no measurable change (p = 1.000) |
  | Launch to history loaded | 0.65 (0.61 to 0.69) s | 0.60 (0.57 to 1.34) s | -0.05 s, -7.7% | no measurable change (p = 0.431) |
  | CPU from launch to the idle window | 1.90 (1.81 to 2.19) s | 1.88 (1.80 to 1.91) s | -0.01 s, -0.5% | no measurable change (p = 0.418) |
  | CPU energy from launch to the idle window | 5.37 (4.22 to 6.02) J | 5.80 (5.56 to 6.26) J | +0.43 J, +8.1% | no measurable change (p = 0.368) |
  | Python helper start to ready, no network | 0.32 (0.30 to 0.57) s | 0.35 (0.28 to 0.65) s | +0.03 s, +9.4% | no measurable change (p = 0.844) |
  | Python helper start, CPU | 0.32 (0.29 to 0.36) s | 0.34 (0.28 to 0.40) s | +0.02 s, +6.3% | no measurable change (p = 0.797) |
  | Python helper memory once started | 71.1 (71.1 to 71.3) MB | 71.0 (71.0 to 71.2) MB | -0.0 MB, -0.1% | no measurable change (p = 0.121) |

- On real data: not measured. What the switch saves is in pull request
  86's entry, and is still theoretical: at the default five-minute refresh,
  app and helper together are expected to average about 114 MB in place of
  the 175 MB measured on the installed 3.7.0, for about 0.06 s/min more
  CPU. Sampling the owner's Mac with the switch on, with
  `Scripts/measure_performance.sh`, would turn that into a measurement.
- Testing: 724 XCTest tests with 0 failures; the pool's test now checks that
  an unchanged setting is on, that turned off the app's pool keeps its
  workers for 15 minutes without a restart, and that a pool given no
  timeout keeps them for 15 minutes. 66 Python helper tests and 91 script
  tests pass. `checks`, `docs-check` and `build-release` pass.

  The switch was read on screen, driven by Sonnet, in an isolated copy of
  the measured build of `ea7aa22` (made-up data, live providers off, a new
  store). Under Settings → Advanced → Memory it was on, and its description
  read word for word as in the diff. Roll Digits When Figures Change was on
  too. Nothing was clicked. Afterwards none of the copy's four settings
  files held `pythonHelper.quitWhenIdle`, so the switch showed the default,
  not a stored value.
- Known issues:
  - Everyone who never changed the switch gets the new behaviour. At a
    refresh interval of five minutes or longer, every refresh pass starts a
    helper: about a third of a second of CPU, and that pass's first price
    arrives about as much later.
  - A settings export carries only settings that were changed. Importing
    one made before the switch was turned off, or by a build without the
    switch, leaves it on.
- Verdict: retained. The owner's decision, made knowing the trade.

### 103: Note in `requirements.txt` that its pins have GitHub's advisory fixes

- What: two comment lines in `Stockbar/Resources/requirements.txt`, saying
  that the `requests` and `urllib3` pins have the fixes for the eight
  advisories GitHub raised against them. No pin changes.

  The point is the change itself. `main` has pinned `urllib3==2.8.0` and
  `requests==2.34.2` since `c61f882` (2026-11-05 13:27 UTC), but GitHub's
  dependency graph still holds the file as it was at that commit, whose
  lines for Apple's Python 3.9 pinned `urllib3==1.26.20` and
  `requests==2.32.5`. So eight Dependabot alerts stayed open, and a new
  advisory would be matched against versions Stockbar does not install.
  The graph has re-read the workflow files and `Package.resolved` since,
  but not this file, which no push to `main` has changed since 2026-11-05
  15:02 UTC. A change to the file on `main` is expected to make GitHub read
  it again. The owner chose on 2026-11-13 to dismiss the eight alerts as
  inaccurate at once, which was done the same day, and to let this change
  reach `main` with the next promotion.
- Merged: 2026-11-13, squash commit `25b450d`. The merge published
  experimental build 370.16.4 as the prerelease `experimental-370.16.4`.
  Checked after it: the feed's signature and the archive's signature are
  valid, the archive's length matches the feed, the unpacked app is build
  370.16.4 of 3.7.0 and its bundled `requirements.txt` carries the new
  comment, its code signature verifies and its executable has no
  `__llvm_prf` section. `main` and `testing` did not move.
- Benchmark: not run, and all fifteen rows are "not measured". The one file
  of the app that changes is this text file, and only in comments. The
  launch-time check reads it for its pins and skips comment lines, as its
  tests show. Deferred to the next milestone comparison.
- Testing: `bash script/update_python_lock.sh --check`, which CI runs,
  reports that `requirements.lock` still matches. The 7
  `PythonRequirementsTests` pass with 0 failures. The script tests, the 66
  Python helper tests, `checks` and `docs-check` pass.
- Known issues:
  - That GitHub reads the file again when it changes on `main` is
    expected, not verified: GitHub does not say what makes it re-read a
    file. If the graph is still stale after the change reaches `main`, the
    next step is to ask GitHub Support.
  - Until then, Dependabot matches new advisories for `urllib3`,
    `requests` and `yfinance` against old versions. A fix for the versions
    Stockbar installs could be missed, and a stale alert raised.
- Verdict: retained.

### 104: Read and write the Python helper's quote cache once per refresh

- What: finding 1 of the
  [review of the refresh path](#review-of-the-refresh-path-2026-11-13).
  `get_stock_data.py` read its quote cache file three times for each symbol
  of a refresh and rewrote the whole file, forcing it to disk twice, once
  for each symbol fetched. Now a refresh reads the file once to look up
  every symbol, and stores everything it fetched with one locked read,
  merge and atomic write at the end. The lock, the atomic replace and both
  forced writes are unchanged, and entries another process stored meanwhile
  are kept. Nothing is written when every symbol came from the cache.
  `get_cached` and `set_cache` are replaced by `get_cached_quotes` and
  `update_cache`; `fetch_batch` no longer reads or writes the cache, which
  `main` does around it. A symbol given twice is fetched once, as before,
  when the second lookup found the first one's cached quote.
- Merged: 2026-11-13, squash commit `19a51de`. The merge published
  experimental build 370.16.5 as the prerelease `experimental-370.16.5`.
  Checked after it: the feed's signature and the archive's signature are
  valid, the archive's length matches the feed, the unpacked app is build
  370.16.5 of 3.7.0 and its bundled `get_stock_data.py` has the new cache
  functions, its code signature verifies and its executable has no
  `__llvm_prf` section. `main` and `testing` did not move.
- Measured offline, with `measure.py` (not in the repository): `main()` run
  with fresh globals, as the app's worker runs it, on a cache that holds a
  stale entry for every symbol, which is its state at each refresh. The
  provider fetch was replaced by a stub that returns a full quote, and the
  one-second spacing between requests was skipped. Fifty calls a side, in
  ten alternating rounds of five, on 2026-11-13 from 10:50 to 10:51 UTC.
  Before is the script at `25b450d`, after is this pull request's. Median
  (range):

  | Per refresh | Before, 22 symbols | After, 22 symbols | Before, 50 symbols | After, 50 symbols |
  | --- | --- | --- | --- | --- |
  | Reads of the cache file | 66 | 2 | 150 | 2 |
  | Writes of the cache file | 22 | 1 | 50 | 1 |
  | Forced writes to disk | 44 | 2 | 100 | 2 |
  | Bytes written | 296,509 (296,250 to 296,864) | 13,476 (13,449 to 13,504) | 1,531,399 (1,530,093 to 1,533,174) | 30,621 (30,560 to 30,680) |
  | CPU | 20.9 (19.8 to 25.2) ms | 1.5 (1.2 to 2.7) ms | 80.4 (77.0 to 103.3) ms | 2.4 (2.1 to 3.1) ms |
  | Elapsed | 21.4 (20.0 to 25.8) ms | 1.6 (1.2 to 5.4) ms | 81.2 (77.8 to 114.5) ms | 2.4 (2.1 to 3.3) ms |

  22 symbols is the benchmark fixture's portfolio. The time a refresh
  spends waiting for the provider, about a second a symbol, is not
  changed.
- Benchmark: before `25b450d`, after `22f7565` (the code commit; the
  second commit changes only this log), six launches a side in turns from
  10:54 to 11:29 UTC on 2026-11-13, macOS 27.2.1 and mains power, all
  twelve launches with the screen unlocked and the display awake. The load
  average was 5.9 when the run started and 4.4 when it ended. Named in
  advance: no row expected to move. The benchmark never fetches a price, and
  its three helper rows start the helper without running this script. No
  row moved.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 100.8 (100.4 to 101.5) MB | 101.3 (99.2 to 102.4) MB | +0.5 MB, +0.4% | no measurable change (p = 0.671) |
  | Idle memory the app holds allocated | 55.9 (55.6 to 56.6) MB | 56.1 (54.0 to 56.9) MB | +0.2 MB, +0.4% | no measurable change (p = 0.671) |
  | Peak memory, launch and history load | 250.4 (243.4 to 264.2) MB | 253.2 (248.6 to 259.8) MB | +2.8 MB, +1.1% | no measurable change (p = 0.729) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.0) MB | 0.0 (-0.1 to 0.1) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.172 (0.159 to 0.203) s/min | 0.167 (0.165 to 0.171) s/min | -0.005 s/min, -2.9% | no measurable change (p = 0.095) |
  | Idle CPU wake-ups | 25 (24 to 27) /min | 26 (25 to 28) /min | +2 /min, +6.0% | no measurable change (p = 0.184) |
  | Idle CPU power | 4.48 (4.40 to 4.79) mW | 4.53 (4.45 to 4.67) mW | +0.04 mW, +1.0% | no measurable change (p = 0.866) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.60 (0.58 to 0.66) s | 0.56 (0.56 to 0.71) s | -0.04 s, -6.6% | no measurable change (p = 0.065) |
  | Launch to history loaded | 0.59 (0.56 to 0.64) s | 0.58 (0.56 to 0.76) s | -0.01 s, -1.7% | no measurable change (p = 0.848) |
  | CPU from launch to the idle window | 2.06 (2.01 to 2.19) s | 2.08 (2.04 to 2.16) s | +0.02 s, +0.7% | no measurable change (p = 0.617) |
  | CPU energy from launch to the idle window | 6.07 (5.58 to 6.32) J | 6.25 (5.98 to 6.52) J | +0.18 J, +3.0% | no measurable change (p = 0.180) |
  | Python helper start to ready, no network | 0.42 (0.29 to 0.61) s | 0.31 (0.28 to 0.58) s | -0.11 s, -25.3% | no measurable change (p = 0.387) |
  | Python helper start, CPU | 0.39 (0.29 to 0.41) s | 0.30 (0.27 to 0.38) s | -0.09 s, -23.1% | no measurable change (p = 0.139) |
  | Python helper memory once started | 71.0 (70.0 to 71.4) MB | 71.2 (71.0 to 71.5) MB | +0.1 MB, +0.1% | no measurable change (p = 0.180) |

  Not measured by it: the change itself, which is measured offline above.
- Testing: the 69 Python helper tests pass, three of them new: a refresh of
  twelve symbols, one of them given twice, reads the file twice, writes it
  once, fetches each symbol once and keeps the entry already stored for a
  symbol it was not asked for; a refresh served from
  the cache writes nothing; a fresh entry that is not a valid quote is
  fetched again and replaced, or dropped when the fetch fails. The test of
  eight processes storing at once still finds all eight entries. The
  single-symbol text-mode test now uses a different symbol for its no-data
  half, because its first half's quote is now cached by `main`, not by the
  `fetch_batch` the test replaces with a mock. 724 XCTest tests pass with
  0 failures, as do the 91 script tests, `checks` and `docs-check`. Every
  path of `main` ran in the offline measurement and the tests, with the
  provider replaced; no live provider was called.
- Known issues:
  - A quote fetched in a refresh that then fails as a whole, with an
    exception outside the per-symbol fetches, is no longer cached. Before,
    each quote was stored as soon as it arrived. The refresh reports a
    network error either way, and the next one fetches again.
  - The app stops the helper after the batch's time limit as a backstop.
    A refresh stopped that way stores nothing, where before it kept the
    quotes fetched so far. The script stops starting new symbols 15 seconds
    before that limit, and gives up waiting on any one symbol by then, so
    this needs the script to overrun its own time limit by 15 seconds.
- Verdict: retained.

### 105: Add a refresh workload to the benchmark

- What: the benchmark keeps live providers off, so it never refreshed a
  price and could not measure the refresh path, where findings 5 to 9 of
  the [review](#review-of-the-refresh-path-2026-11-13) lie.
  `Scripts/perf/benchmark.sh --refresh`, and `compare.sh --refresh`, now
  make as many launches again after the usual ones. `--settle` seconds
  after each, the script sends the app `SIGUSR1`, and the app runs four
  "Refresh now" passes, 30 s apart, on made-up quotes, with no network and
  no Python. Chart Data Collection is set to 30 s for these runs, so
  every pass records price rows and a portfolio snapshot, as every refresh
  does at the default settings. CPU, CPU energy, wake-ups, disk writes,
  footprint and heap growth over those 120 s get seven rows of their own,
  shown only when a side measured them.

  In the app, `BenchmarkRefreshSettings` takes the workload only in an
  acceptance run with live providers off whose environment asks for it.
  `DataModel` then uses `BenchmarkQuoteService`, which refuses every quote,
  as the Python service does in an acceptance run, until the signal
  arrives. So the launch and the idle window are measured as without it.
  `BenchmarkRefreshDriver` runs the passes through the refresh service's
  normal forced path. A build without the workload never logs that it is
  ready, is not signalled, and shows "not measured" on its side of the new
  rows; the report now shows a side's figures when only that side measured
  a row. Without `--refresh` nothing changes, and a comparison still takes
  about 35 minutes; with it, about 75. `Scripts/README_PERFORMANCE.md` and
  `Docs/Architecture.md` describe it.

  The first version measured the refreshes in the same launches, after the
  idle window. Its comparison, before `19a51de` and after `03af500`, from
  11:47 to 12:41 UTC, was set aside: a refresh changes the stored data the
  next launch starts from, and in the second and third launch of each of
  this branch's turns the idle window drew 0.39 to 0.45 mW of CPU power
  against 4.51 to 4.76 mW in every other launch, and used 0.085 to 0.104
  s/min of CPU against 0.157 to 0.174. So the usual rows were no longer
  measured on the same data as the other build's. What makes the idle
  window cheaper after a refresh was not looked into; the benchmark's
  fixture holds prices last updated when it was made, marked closed. Its
  refresh rows were steady: 7.01 to 7.28 s of CPU and 23.95 to 25.37 J
  over the four passes in all six launches.
- Merged: 2026-11-13, squash commit `93198fc`. The merge published
  experimental build 370.16.6 as the prerelease `experimental-370.16.6`.
  Checked after it: the feed's signature and the archive's signature are
  valid, the archive's length matches the feed, the unpacked app is build
  370.16.6 of 3.7.0 and carries the workload, its code signature verifies
  and its executable has no coverage counters. `main` and `testing` were
  unchanged.
- A first launch with the workload, from this branch on 2026-11-13 at 11:39
  UTC: all four passes completed and updated 13 symbols each. Over the 120
  s the app used 7.29 s of CPU and 25.5 J of CPU energy, woke 699 times,
  wrote 0.05 MB, and held 35.3 MB more allocated afterwards than before;
  its footprint was 144.3 MB against 100.4 MB idle. The first pass took
  0.7 s from start to "Refresh completed", the later ones 1.7 to 1.8 s.
  That is about 1.7 s of CPU a pass for eleven holdings, against 0.19 s a
  minute idle, so the refresh path is where most of the app's work goes
  while prices are being fetched. One launch, so read it as an order of
  size; the comparison below has six. The benchmark's launches show the
  main window, which redraws as prices change; how much of that cost is the
  window's is for finding 6 to look into.
- Benchmark: before `19a51de`, after `97bb986` (the second of the two
  code commits; the commits after it change only this log and one comment
  in `compare_report.py`), with `--refresh`:
  six launches a side in turns from 12:36 to 13:29 UTC on 2026-11-13,
  macOS 27.2.1 and mains power, the screen unlocked and the display awake
  in every launch and every refresh window. The load average was 5.8 when
  the run started and 3.3 when it ended. Named in advance: no usual row
  expected to move, since the workload refuses quotes as before until it is
  signalled, and the refresh launches come after the others. No usual row
  moved. The refresh rows are this pull request's to add, so the build
  before it has none; they are the figures later pull requests are
  measured against.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 101.0 (100.3 to 103.6) MB | 101.4 (100.7 to 102.9) MB | +0.4 MB, +0.3% | no measurable change (p = 0.617) |
  | Idle memory the app holds allocated | 56.0 (55.2 to 56.4) MB | 56.1 (55.4 to 56.4) MB | +0.1 MB, +0.3% | no measurable change (p = 0.504) |
  | Peak memory, launch and history load | 249.3 (246.4 to 257.0) MB | 248.1 (244.1 to 253.7) MB | -1.2 MB, -0.5% | no measurable change (p = 0.416) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.1) MB | 0.1 (0.0 to 0.1) MB | +0.1 MB | no measurable change (p = 0.545) |
  | Idle CPU | 0.168 (0.161 to 0.172) s/min | 0.164 (0.154 to 0.168) s/min | -0.004 s/min, -2.1% | no measurable change (p = 0.240) |
  | Idle CPU wake-ups | 24 (23 to 29) /min | 24 (23 to 26) /min | +0 /min, +2.1% | no measurable change (p = 0.740) |
  | Idle CPU power | 4.56 (4.38 to 4.72) mW | 4.59 (4.27 to 4.76) mW | +0.03 mW, +0.5% | no measurable change (p = 0.851) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.58 (0.52 to 0.62) s | 0.58 (0.57 to 0.63) s | +0.01 s, +0.9% | no measurable change (p = 0.420) |
  | Launch to history loaded | 0.59 (0.56 to 0.82) s | 0.63 (0.58 to 0.72) s | +0.04 s, +6.8% | no measurable change (p = 0.452) |
  | CPU from launch to the idle window | 2.02 (2.01 to 2.19) s | 2.07 (1.98 to 2.23) s | +0.05 s, +2.5% | no measurable change (p = 0.387) |
  | CPU energy from launch to the idle window | 6.25 (5.75 to 6.51) J | 6.37 (5.53 to 6.54) J | +0.12 J, +1.9% | no measurable change (p = 0.513) |
  | Python helper start to ready, no network | 0.33 (0.28 to 0.63) s | 0.28 (0.28 to 0.57) s | -0.05 s, -15.2% | no measurable change (p = 0.372) |
  | Python helper start, CPU | 0.32 (0.28 to 0.40) s | 0.28 (0.28 to 0.36) s | -0.04 s, -12.5% | no measurable change (p = 0.351) |
  | Python helper memory once started | 71.1 (71.0 to 71.3) MB | 71.0 (71.0 to 71.1) MB | -0.0 MB, -0.1% | no measurable change (p = 0.448) |
  | Refresh passes completed in the refresh window | not measured | 4 (4 to 4) passes | | |
  | CPU over the refresh window | not measured | 7.360 (7.220 to 7.422) s | | |
  | CPU energy over the refresh window | not measured | 25.569 (24.613 to 25.705) J | | |
  | CPU wake-ups over the refresh window | not measured | 718 (702 to 759) wake-ups | | |
  | Disk writes over the refresh window | not measured | 0.046 (0.046 to 1.406) MB | | |
  | Memory during the refresh window (physical footprint) | not measured | 142.2 (136.1 to 146.0) MB | | |
  | Allocated memory added by the refreshes | not measured | 36.5 (34.6 to 53.1) MB | | |

  The disk writes are 0.046 MB in four of the six refresh launches and 1.4
  MB in the other two, each the third refresh launch of its turn, which
  also added 50.8 and 53.1 MB of allocated memory against 34.6 to 37.2 in
  the others. What happens in the third launch was not looked into.
- Testing: 726 XCTest tests pass with 0 failures, two of them new: the
  workload is taken only in an acceptance run with live providers off
  whose environment asks for it, with figures in range; and the quotes are
  refused as in any acceptance run until the service is armed, then move
  with each batch from a fixed price per symbol, while history stays
  refused. The 92 script tests pass, one of them new: refresh rows appear
  only when a side measured them, with that side's figures. `checks` and
  `docs-check` pass. Two runs of the benchmark itself, a trial launch and
  the comparison above, completed all four passes in every refresh launch.
- Known issues:
  - The benchmark's launches keep the main window open, as they always
    have, and it redraws as prices change. In normal use it is closed. So
    the refresh rows include a window that is usually not there.
    (Corrected on 2026-11-13: the app shows the window at every launch, and
    a closed window goes on redrawing, so the refresh rows are those of
    normal use. See
    [Findings 6 and 7 looked into](#findings-6-and-7-looked-into-2026-11-13).)
  - The refresh launches start from the data the one before left, so
    their figures drift a little across a turn. Both sides run the same
    sequence.
  - A build from before this pull request shows a warning that its
    launches "were builds without the refresh workload".
- Verdict: retained.

### 106: Apply a refresh pass's quotes together before waiting on anything

- What: the first change chosen after
  [Findings 6 and 7 looked into](#findings-6-and-7-looked-into-2026-11-13).
  `RefreshService.runRefreshPass` applied one symbol's quote, then waited
  on the cache actor and on the logger before the next symbol. Each wait
  let other main-actor work run, so SwiftUI redrew the main window, open
  or closed, once for each symbol. Now `applyQuotes` applies every
  result, with its price sample and alert check, without waiting on
  anything, and `recordPassOutcome` then does the cache bookkeeping and
  the log lines. The quote status, the save, the portfolio sample and the
  snapshot task now come before the cache and log calls instead of after
  them. The symbols, the values recorded, the failure handling and the
  back-off are unchanged. Holdings are still looked up by name, so a
  symbol held in two rows still updates the first of them each time it is
  listed. No Rust, native macOS API, dependency or architectural change.
- Merged: 2026-11-13, squash commit `f1dce15`, after the owner chose to
  merge it with the wake-up trade-off below. The merge published
  experimental build 370.16.7 as the prerelease `experimental-370.16.7`.
  Checked after it: the feed's signature and the archive's signature are
  valid, the archive's length matches the feed, the unpacked app is build
  370.16.7 of 3.7.0 and carries `applyQuotes`, its code signature verifies
  and its executable has no coverage counters. The build job waited 23
  minutes for a runner and then took its usual 4. `main` and `testing`
  were unchanged.
- Redraws counted in the trial copy, with the counters of
  [Findings 6 and 7 looked into](#findings-6-and-7-looked-into-2026-11-13)
  applied to this branch's code commit `cd291fa` and run on the same
  fixture in the same way on 2026-11-13 from 14:19 to 14:30 UTC: four
  forced passes 30 s apart, with the window open, closed, and open again.
  The trial copy is never committed. One launch each, so read the CPU
  figures as an order of size; the benchmark below has six a side.

  | Per refresh pass | Before (`93198fc`) | After (`cd291fa`) |
  | --- | --- | --- |
  | Main window redraws | 18 to 19 | 5 |
  | Menu bar item updates | 33 | 33 |
  | Pass, start to end | 0.73 to 0.80 s | 0.29 to 0.42 s |
  | App CPU over the 120 s, window open | 3.60 and 3.59 s/min | 1.64 and 1.63 s/min |
  | App CPU over the 120 s, window closed | 3.80 s/min | 1.93 s/min |

  What each of the five remaining redraws comes from was not looked into.
  The 33 menu bar updates are finding 6's, the next pull request.
- Benchmark: before `93198fc`, after `cd291fa` (the code commit; the
  commit after it changes one comment and this log), with `--refresh`:
  six launches a side in turns, from 14:30 to 15:45 UTC on 2026-11-13,
  macOS 27.2.1. The Mac was on battery power for this run, where the
  earlier comparisons were on mains power, so its figures are not
  comparable with theirs: idle CPU, for one, is 0.080 s/min here against
  0.164 to 0.168 in pull request 105's run. Both sides of this run were
  measured in the same conditions, and the report flagged no launch for a
  locked screen or a sleeping display. No usual row moved. Four refresh
  rows moved, three of them down and one up:

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 96.8 (94.6 to 98.0) MB | 96.1 (90.7 to 100.0) MB | -0.7 MB, -0.7% | no measurable change (p = 1.000) |
  | Idle memory the app holds allocated | 52.2 (49.5 to 52.8) MB | 52.1 (50.4 to 53.8) MB | -0.1 MB, -0.1% | no measurable change (p = 0.729) |
  | Peak memory, launch and history load | 252.9 (247.1 to 260.2) MB | 254.8 (239.6 to 261.4) MB | +1.9 MB, +0.8% | no measurable change (p = 0.699) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.0) MB | 0.0 (-2.1 to 0.5) MB | +0.0 MB | no measurable change (p = 0.727) |
  | Idle CPU | 0.080 (0.077 to 0.083) s/min | 0.084 (0.078 to 0.090) s/min | +0.004 s/min, +5.6% | no measurable change (p = 0.149) |
  | Idle CPU wake-ups | 26 (24 to 27) /min | 24 (23 to 26) /min | -1 /min, -3.9% | no measurable change (p = 0.335) |
  | Idle CPU power | 4.05 (3.99 to 4.19) mW | 4.11 (3.41 to 4.26) mW | +0.05 mW, +1.4% | no measurable change (p = 0.729) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.56 (0.52 to 0.60) s | 0.56 (0.52 to 0.97) s | -0.01 s, -0.9% | no measurable change (p = 0.792) |
  | Launch to history loaded | 0.58 (0.55 to 0.74) s | 0.60 (0.54 to 0.90) s | +0.02 s, +3.4% | no measurable change (p = 1.000) |
  | CPU from launch to the idle window | 1.81 (1.74 to 1.98) s | 1.81 (1.75 to 1.98) s | +0.00 s, +0.3% | no measurable change (p = 0.835) |
  | CPU energy from launch to the idle window | 5.78 (5.66 to 6.11) J | 5.90 (5.67 to 6.39) J | +0.12 J, +2.2% | no measurable change (p = 0.310) |
  | Python helper start to ready, no network | 0.29 (0.28 to 0.64) s | 0.29 (0.28 to 0.61) s | -0.01 s, -3.4% | no measurable change (p = 0.394) |
  | Python helper start, CPU | 0.29 (0.28 to 0.39) s | 0.29 (0.28 to 0.36) s | -0.00 s, -1.7% | no measurable change (p = 0.589) |
  | Python helper memory once started | 71.1 (71.0 to 71.3) MB | 71.0 (71.0 to 71.1) MB | -0.1 MB, -0.1% | no measurable change (p = 0.405) |
  | Refresh passes completed in the refresh window | 4 (4 to 4) passes | 4 (4 to 4) passes | +0 passes | no measurable change (p = 1.000) |
  | CPU over the refresh window | 6.797 (6.722 to 6.922) s | 3.367 (3.292 to 3.486) s | -3.430 s, -50.5% | lower (p = 0.002) |
  | CPU energy over the refresh window | 23.674 (22.946 to 24.269) J | 11.267 (10.939 to 11.526) J | -12.407 J, -52.4% | lower (p = 0.002) |
  | CPU wake-ups over the refresh window | 683 (641 to 775) wake-ups | 902 (822 to 987) wake-ups | +218 wake-ups, +32.0% | higher (p = 0.002) |
  | Disk writes over the refresh window | 0.046 (0.046 to 1.406) MB | 0.046 (0.046 to 1.406) MB | +0.000 MB | no measurable change (p = 1.000) |
  | Memory during the refresh window (physical footprint) | 141.6 (138.0 to 148.0) MB | 131.2 (128.4 to 135.1) MB | -10.4 MB, -7.3% | lower (p = 0.002) |
  | Allocated memory added by the refreshes | 49.9 (46.9 to 52.8) MB | 27.9 (24.9 to 29.3) MB | -22.0 MB, -44.1% | lower (p = 0.002) |

  The wake-ups are the trade-off: 218 more over the four passes, about
  55 a pass, while CPU and CPU energy halve. The trial copy shows the same
  direction, 355 against 536 wake-ups a minute with the window open.

  The likely cause is the main window's rolling digits, which animate
  when prices change: before this change the main thread was too busy
  redrawing to run many of their frames. To check, the trial copy of
  `cd291fa` ran three more launches on 2026-11-13 from 15:46 to 15:59 UTC,
  on battery power, with the rolling digits on, off, and on again:

  | Over the 120 s of refreshes | Rolling on | Rolling off | Rolling on again |
  | --- | --- | --- | --- |
  | App CPU wake-ups | 426 /min | 340 /min | 440.5 /min |
  | App CPU | 1.66 s/min | 0.99 s/min | 1.73 s/min |
  | App CPU power | 91.8 mW | 53.4 mW | 96.2 mW |

  With them off, the change's wake-ups are below the 355 a minute of the
  code before it with them on. The code before it was not run with them
  off, and each figure is from one launch. The wake-ups with them on vary
  from launch to launch: 426 to 536 a minute across this branch's four
  such launches.
- Testing: 727 XCTest tests pass with 0 failures, one of them new: three
  holdings refreshed in one forced pass, with an observer on their prices
  whose follow-up task runs at the pass's first wait, must see all three
  new prices. Against the code before this change it saw
  `[100.0, nan, nan]`. `checks` and `docs-check` pass. The trial copy's
  four passes and every benchmark refresh launch completed and updated
  every symbol. An independent review by a reviewer that had not seen the
  implementation found no defect; what it raised is below and in the
  comment fix.
- Known issues:
  - The order of the log lines changed. Each line's wording is the same,
    but all of a pass's "Updated cache" lines now come before its failure
    lines, and the save and snapshot lines before both.
  - A symbol whose updates are paused after repeated failures, refreshed
    successfully late in a forced pass of several symbols that names it
    without clearing the pause, can keep its "Updates paused" notice in an
    open popover until its next update, because the cache now hears of
    the success a few hops later. The manual retry clears the pause first
    and is not affected, and failures already had the same timing.
  - The code commit's message gives the wrong reason for looking holdings
    up by name. The comment in the code and the squash commit give the
    right one.
- Verdict: retained, by the owner's decision on 2026-11-13. It was left
  open for the owner with a recommendation to retain it: CPU and energy,
  which the wake-ups stand in for, both halve, and the extra wake-ups come
  with the rolling digits, which now get to animate.

### 107: Read only the requested window of a symbol's price history

- What: finding 6 of the
  [Review of the refresh path](#review-of-the-refresh-path-2026-11-13).
  Each menu bar item update reads the last day of its symbol's prices for
  the rolling day change. `HistoricalDataManager.getPriceSnapshots` built
  the symbol's whole combined history, about 2,180 prices on the fixture,
  sorted it and kept the 70 to 85 that fall in the day. The built series
  is cached, but the cache is emptied whenever a stored price or a live
  sample changes, so during a refresh every read built and sorted the
  whole series again. Now `InstrumentAliasHistoryLookup.combinedSnapshots`
  takes an optional window and merges and sorts only the prices inside it.
  The whole series keeps one price per millisecond, so the windowed read
  takes in 2 ms either side of the window, which covers every price that
  could replace one inside it, and then cuts the result to the window.
  `aliasAwarePriceSnapshots` passes the window through: an overlay series
  and a series already in the cache are cut to it, and otherwise the
  window is read from the prices and the cache is left alone. A read of a
  whole series is unchanged and still fills the cache. Every caller of
  `getPriceSnapshots` takes the new path: the menu bar's day change, the
  previous close worked out from yesterday's prices, the popover chart
  and its comparison symbol, the check for whether a chart needs more
  history, and the analytics correlations. A range whose start is after
  its end returns nothing, as before. No Rust, native macOS API,
  dependency or architectural change.
- Merged: 2026-11-13, squash commit `0a1ea40`. The merge published
  experimental build 370.16.8 as the prerelease `experimental-370.16.8`.
  Checked after it: the feed's signature and the archive's signature are
  valid, the archive's length matches the feed, the unpacked app is build
  370.16.8 of 3.7.0 and carries `cachedSnapshots`, its code signature
  verifies and its executable has no coverage counters. The build job
  started three seconds after the merge, with no wait for a runner, and
  took 5 minutes. `main` and `testing` were unchanged.
- The read timed in the trial copy, with the counters of
  [Findings 6 and 7 looked into](#findings-6-and-7-looked-into-2026-11-13)
  and a timer around the day read applied to `f1dce15` and to this
  branch's code commit `d5acb72`. Same fixture, on 2026-11-13 from 17:31
  to 17:47 UTC on mains power: two launches a side with the main window
  open, each with four forced passes 30 s apart. The trial copy is never
  committed. Its output is kept in
  `build/bench/results/trial-day-window-20261113`.

  | Per launch | Before (`f1dce15`) | After (`d5acb72`) |
  | --- | --- | --- |
  | Day reads | 154 and 154 | 154 and 154 |
  | One day read, median | 2,622 and 2,691 µs | 57 and 60 µs |
  | One day read, fastest to slowest | 2,336 to 3,256 µs | 48 to 575 µs |
  | All the launch's day reads together | 406 and 419 ms | 11 and 14 ms |
  | Prices each read returned | 70 to 78, then 74 to 81 | 70 to 78, then 74 to 81 |
  | App CPU over the 120 s of refreshes | 1.58 and 1.52 s/min | 1.35 and 1.38 s/min |
  | App CPU power over the 120 s | 82.8 and 81.6 mW | 71.1 and 69.1 mW |
  | App CPU wake-ups over the 120 s | 868 and 762 /min | 850 and 832 /min |

  Sorted by symbol, the number of prices each read returned is the same
  list before and after in both launches. The menu bar item updates and
  the main window redraws were counted too and did not change. With two
  launches a side, read the CPU, power and wake-up rows as an order of
  size; the benchmark below has six a side.
- Benchmark: before `f1dce15`, after `d5acb72` (the code commit; the
  commit after it changes only this log), with `--refresh`: six launches
  a side in turns, from 17:48 to 19:04 UTC on 2026-11-13, macOS 27.2.1,
  on mains power. The report flagged no launch. Pull request 106's run
  was on battery power, so the two runs' figures are not comparable: the
  same app code, `f1dce15` here and `cd291fa` there, shows 1,559 wake-ups
  over the refresh window here against 902 there, and 1.28 s from launch
  to first window against 0.56 s. About 9.7 GB of old build folders had
  also been deleted from this Mac half an hour before the run. Which of
  the two accounts for the slower launches was not looked into. The
  before side is the current `experimental` measured again in this run,
  so both sides share the conditions. One refresh row moved, down:

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 86.4 (84.8 to 87.1) MB | 85.7 (83.6 to 90.5) MB | -0.8 MB, -0.9% | no measurable change (p = 0.615) |
  | Idle memory the app holds allocated | 47.5 (40.3 to 47.9) MB | 47.0 (46.3 to 48.4) MB | -0.5 MB, -0.9% | no measurable change (p = 1.000) |
  | Peak memory, launch and history load | 233.8 (230.2 to 248.8) MB | 234.3 (227.0 to 243.1) MB | +0.5 MB, +0.2% | no measurable change (p = 0.937) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.1) MB | 0.0 (-0.2 to 0.1) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Idle CPU | 0.084 (0.069 to 0.091) s/min | 0.080 (0.075 to 0.100) s/min | -0.005 s/min, -5.4% | no measurable change (p = 1.000) |
  | Idle CPU wake-ups | 26 (24 to 30) /min | 26 (24 to 30) /min | +0 /min, +0.0% | no measurable change (p = 0.931) |
  | Idle CPU power | 4.33 (4.16 to 4.61) mW | 4.03 (3.84 to 4.32) mW | -0.30 mW, -7.0% | possibly lower (p = 0.045) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 1.28 (0.68 to 1.35) s | 1.31 (0.66 to 1.61) s | +0.03 s, +2.7% | no measurable change (p = 0.667) |
  | Launch to history loaded | 1.26 (0.73 to 1.32) s | 1.27 (0.65 to 1.56) s | +0.01 s, +0.4% | no measurable change (p = 0.667) |
  | CPU from launch to the idle window | 1.92 (1.64 to 2.06) s | 1.77 (1.57 to 1.91) s | -0.15 s, -8.1% | no measurable change (p = 0.132) |
  | CPU energy from launch to the idle window | 5.67 (5.30 to 6.04) J | 5.49 (4.90 to 5.66) J | -0.18 J, -3.2% | no measurable change (p = 0.093) |
  | Python helper start to ready, no network | 0.30 (0.30 to 0.66) s | 0.33 (0.32 to 0.67) s | +0.03 s, +8.2% | no measurable change (p = 0.173) |
  | Python helper start, CPU | 0.30 (0.29 to 0.42) s | 0.33 (0.31 to 0.42) s | +0.03 s, +8.3% | no measurable change (p = 0.195) |
  | Python helper memory once started | 71.0 (71.0 to 71.2) MB | 71.1 (71.0 to 71.3) MB | +0.0 MB, +0.1% | no measurable change (p = 0.675) |
  | Refresh passes completed in the refresh window | 4 (4 to 4) passes | 4 (4 to 4) passes | +0 passes | no measurable change (p = 1.000) |
  | CPU over the refresh window | 2.963 (2.756 to 3.660) s | 2.715 (2.324 to 3.012) s | -0.248 s, -8.4% | no measurable change (p = 0.065) |
  | CPU energy over the refresh window | 9.387 (8.828 to 11.150) J | 8.246 (6.888 to 9.302) J | -1.141 J, -12.2% | lower (p = 0.009) |
  | CPU wake-ups over the refresh window | 1559 (1237 to 1660) wake-ups | 1668 (1333 to 1816) wake-ups | +110 wake-ups, +7.0% | no measurable change (p = 0.310) |
  | Disk writes over the refresh window | 0.046 (0.046 to 1.406) MB | 0.046 (0.046 to 1.578) MB | +0.000 MB | no measurable change (p = 1.000) |
  | Memory during the refresh window (physical footprint) | 116.7 (113.4 to 124.9) MB | 115.9 (97.8 to 120.1) MB | -0.8 MB, -0.7% | no measurable change (p = 0.667) |
  | Allocated memory added by the refreshes | 31.5 (29.4 to 36.8) MB | 33.9 (12.4 to 39.7) MB | +2.4 MB, +7.6% | no measurable change (p = 0.699) |

  CPU energy over the four passes is 12.2% lower. CPU over them is 8.4%
  lower at the median, which is inside this run's spread, so it is
  recorded as no measurable change. Its size agrees with the timing
  above: about 0.4 s of reads removed from a launch's four passes. The
  "possibly lower" idle power is a row the report says needs a repeat
  before it counts, and it is not counted here. No row is higher.
- Testing: 729 XCTest tests pass with 0 failures, two of them new. One
  compares a windowed read with the whole series cut to the same window,
  across two aliases, live samples on an alias, windows whose edges fall
  inside a millisecond, a single instant and a window over everything.
  It includes a live sample 0.97 ms before a window's start that shares
  a millisecond with a stored price just inside it and wins over it, so a
  read that reached less than 0.97 ms past the edge would return the
  stored price. The other covers the cache lookup: a miss stores
  nothing, a hit counts as a use, and a series stored under a different
  alias list is dropped. The existing rolling-window test also reads a
  window from a cached series and an inverted range. `checks` and
  `docs-check` pass. The trial copies' four measured launches completed
  their four passes. An independent review by a reviewer that had not seen the
  implementation found no defect; what it raised went into the second
  code commit: the margin test above, the stale cache entry and the
  wording of two comments.
- Known issues:
  - A windowed read no longer fills the cache. A second read of the same
    symbol while no price has changed, such as switching the popover
    chart's range, changing its comparison symbol or recalculating the
    analytics correlations, was served from the cache and now reads its
    window from the prices again. This was not measured. For a window
    that spans the whole history it is the same work as the old read,
    which took 2.6 ms for 2,180 prices above; for a shorter window it is
    less. These reads follow something the user does; none is in a
    redraw.
  - The first code commit, `661207c`, read 1 ms either side of the
    window, which floating-point rounding at the edge could fall short
    of. The second, `d5acb72`, widens it to 2 ms.
  - The second code commit's message says the test's pair of prices sits
    either side of a window's end and needs a margin over 1 ms. They sit
    either side of its start and need 0.97 ms. This entry and the squash
    commit give it correctly.
- Verdict: retained. The read is about 45 times faster, CPU energy over
  the refresh window is lower, and no row is higher. The gain is modest
  at the size of a whole refresh: about a quarter of a second of CPU in
  four passes.

### 108: Leave a history cache file alone when its value has not changed

- What: finding 5 of the
  [Review of the refresh path](#review-of-the-refresh-path-2026-11-13).
  `HistoricalDataManager.saveHistoricalData()` runs after every recorded
  portfolio snapshot and stores the portfolio composition, two
  calculation dates and, when there are any, the earliest history dates
  in `CacheManager`. `CacheManager.store` encoded the value and rewrote
  its file every time, so each snapshot rewrote three or four files with
  the contents they already had. Now `store` compares the encoded value
  with the one it holds for the key. When they are the same it leaves
  the file alone, provided the key's last write did not fail and the
  file is still there. A changed value is written as before. What the
  comparison rests on:
  - The value is encoded with sorted keys. Unsorted, `JSONEncoder`
    orders a dictionary's or a struct's keys differently from one
    encoding to the next, so an unchanged value would look changed. A
    standalone check encoded one 20-key dictionary 300 times and got 7
    and 8 different byte sequences in two runs, and a struct holding an
    array of structs gave 2 in each run. With sorted keys both gave 1.
    The check's source and output are kept in
    `build/bench/results/trial-history-cache-20261113/key-order-check`.
  - `store` and `remove` queue their file work while holding the lock,
    so the files change in the same order as the values held in memory.
  - The check for an unchanged value runs on the file queue, after the
    file work queued before it. A key whose write failed is recorded
    until a write of it succeeds, and until then every store of it
    writes, changed or not.
  - A value read from its file counts as held, so the first store after
    a launch leaves the file alone when the value is the same. The read
    is held only if no file work was queued while it was reading.
  - After `clearMemoryCache()`, which the app calls when it is short of
    memory, the next store of each key writes its file once, since
    nothing then says what the file holds.

  The layout of the files is unchanged, so files written by earlier
  versions stay readable and the other way round. No Rust, native macOS
  API, dependency or architectural change.
- Merged: 2026-11-16, squash commit `e03cdd5`. The merge published
  experimental build 370.16.9 as the prerelease `experimental-370.16.9`.
  Checked after it: the feed's signature and the archive's signature are
  valid, the archive's length matches the feed, the unpacked app is build
  370.16.9 of 3.7.0, its code signature verifies and its executable has
  no coverage counters. Its executable carries the names `failedWrites`
  and `queuedFileWork`, which build 370.16.8's does not. The build job
  started two seconds after the merge and took under 6 minutes. `main`
  and `testing` were unchanged. The tool that checks the two signatures
  was lost when the Mac restarted and was written again; before it was
  used it passed build 370.16.8 and rejected a copy of that archive with
  one byte added and a copy of the feed with one version number changed.
- The writes counted in the trial copy, with the counters of
  [Findings 6 and 7 looked into](#findings-6-and-7-looked-into-2026-11-13)
  and two more in `CacheManager`, one for each call of `store` and one
  for each file written, applied to `0a1ea40` and to this branch's code
  commit `9e98e63`. Same fixture, on 2026-11-13 on battery power: two
  launches a side with the main window open, each with four forced
  passes 30 s apart; before from 19:41 to 19:49 UTC and after from 20:03
  to 20:11 UTC. All four launches completed their four passes. The trial
  copy is never committed. Its output and the two counter patches are
  kept in `build/bench/results/trial-history-cache-20261113`.

  | Per launch | Before (`0a1ea40`) | After (`9e98e63`) |
  | --- | --- | --- |
  | Calls of `CacheManager.store` | 15 and 15 | 15 and 15 |
  | Cache files written | 15 and 15 | 1 and 1 |
  | Cache files written during the four passes | 12 and 12 | 0 and 0 |
  | Bytes of file content written | 7,903 and 7,899 | 187 and 187 |
  | Bytes of file content written during the four passes | 6,322 and 6,318 | 0 and 0 |
  | App disk writes over the 120 s of refreshes | 0.023 and 0.023 MB/min | 0.000 and 0.000 MB/min |
  | App CPU over the 120 s | 1.464 and 1.589 s/min | 1.376 and 1.515 s/min |
  | App CPU wake-ups over the 120 s | 701.5 and 759.5 /min | 850.5 and 723.5 /min |
  | App CPU power over the 120 s | 70.05 and 76.19 mW | 67.69 and 69.14 mW |

  The 15 calls are three values stored five times: once after the
  launch's history calculation and once after each pass. The fixture has
  no earliest history dates, so it stores three values where a portfolio
  with history stores four. The one file still written is the date of
  the launch's history calculation, which does change at each launch.
  The CPU, wake-up and power rows overlap between the two sides and, with
  two launches a side, are an order of size only. Other processes were
  keeping this Mac busy straight after the after side, with a load
  average of 8 to 14 at 20:12 UTC; the load during the before side was
  not looked at. The counts of calls, files and bytes do not depend on
  it.
- Benchmark: before `0a1ea40`, after `9e98e63` (the code commit; the
  commits after it change only this log), with `--refresh`: six launches
  a side in turns, from 14:19 to 15:34 UTC on 2026-11-16, macOS 27.2.1,
  on mains power. The report flagged no launch.

  The run was measured on a busy Mac. It was not run on 2026-11-13
  because the Mac was on battery power and busy. On 2026-11-16 the Mac
  had been restarted at about 10:21 UTC, and a start that waited for the
  CPU to be at least 85% idle did not get it in four hours: a file-sync
  process and system processes each held about one core, and another
  job's test runs on the same Mac came in bursts. During the run itself
  two system processes, one of them serving the file sync, were each
  above half a core in 56 and 42 of the 76 once-a-minute readings, and
  another app in 18. The owner
  asked for the work to go on, so the run started without waiting, under
  two rules written into its log before it began: it would be set aside
  and repeated if more than two of the once-a-minute readings inside its
  turns showed keyboard or pointer input in the minute before, or if the
  CPU of the four busiest processes together, averaged over each side's
  turns, was more than 1.5 times higher for one side than the other. No
  reading showed input. The four busiest together averaged 221% of a
  core over the before side's 36 readings and 209% over the after side's
  36, a ratio of 1.06. So the run stands. The installed app, which was
  running on 2026-11-13, was not running. The readings, the
  rules and the scripts are kept beside the results, in
  `build/bench/results/compare-history-cache-20261116-141931/conditions`.

  The figures are not comparable with the run of 2026-11-13. The same
  app code, `0a1ea40` here and `d5acb72` there (they differ only in this
  log), shows 96.5 MB of idle memory here against 85.7 MB there, 54.8 MB
  held allocated against 47.0 MB, 0.58 s from launch to first window
  against 1.31 s, and 3.343 s of CPU over the refresh window against
  2.715 s. Which of the restart, the other work on the Mac and the date
  accounts for each was not looked into. The before side is the current
  `experimental` measured again in this run, so both sides share the
  conditions.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 96.5 (93.3 to 100.5) MB | 93.0 (89.5 to 95.6) MB | -3.5 MB, -3.7% | possibly lower (p = 0.026) |
  | Idle memory the app holds allocated | 54.8 (54.1 to 55.7) MB | 54.5 (51.5 to 55.4) MB | -0.2 MB, -0.4% | no measurable change (p = 0.331) |
  | Peak memory, launch and history load | 244.0 (239.4 to 247.3) MB | 244.4 (241.0 to 249.9) MB | +0.4 MB, +0.2% | no measurable change (p = 0.589) |
  | Idle memory growth across the window | 0.1 (-5.7 to 0.4) MB | 0.0 (-4.2 to 0.6) MB | -0.1 MB | no measurable change (p = 0.848) |
  | Idle CPU | 0.097 (0.072 to 0.103) s/min | 0.097 (0.073 to 0.106) s/min | +0.000 s/min, +0.0% | no measurable change (p = 0.970) |
  | Idle CPU wake-ups | 26 (25 to 29) /min | 27 (26 to 28) /min | +0 /min, +1.9% | no measurable change (p = 0.426) |
  | Idle CPU power | 3.13 (2.96 to 3.94) mW | 3.38 (2.96 to 4.29) mW | +0.25 mW, +8.0% | no measurable change (p = 0.418) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.58 (0.38 to 0.75) s | 0.80 (0.44 to 1.05) s | +0.22 s, +36.8% | no measurable change (p = 0.104) |
  | Launch to history loaded | 0.65 (0.50 to 0.78) s | 0.82 (0.57 to 1.04) s | +0.18 s, +27.1% | no measurable change (p = 0.177) |
  | CPU from launch to the idle window | 1.80 (1.64 to 1.89) s | 1.94 (1.73 to 2.17) s | +0.14 s, +7.5% | no measurable change (p = 0.117) |
  | CPU energy from launch to the idle window | 5.70 (5.53 to 5.91) J | 5.84 (5.59 to 6.16) J | +0.14 J, +2.5% | no measurable change (p = 0.420) |
  | Python helper start to ready, no network | 0.25 (0.23 to 0.88) s | 0.33 (0.25 to 0.60) s | +0.08 s, +32.0% | no measurable change (p = 0.381) |
  | Python helper start, CPU | 0.24 (0.23 to 0.34) s | 0.31 (0.25 to 0.35) s | +0.07 s, +26.5% | no measurable change (p = 0.128) |
  | Python helper memory once started | 71.0 (70.8 to 71.1) MB | 71.2 (70.9 to 71.4) MB | +0.2 MB, +0.2% | no measurable change (p = 0.067) |
  | Refresh passes completed in the refresh window | 4 (4 to 4) passes | 4 (4 to 4) passes | +0 passes | no measurable change (p = 1.000) |
  | CPU over the refresh window | 3.343 (3.216 to 3.504) s | 3.408 (3.256 to 3.584) s | +0.065 s, +1.9% | no measurable change (p = 0.589) |
  | CPU energy over the refresh window | 10.885 (10.720 to 11.290) J | 10.771 (10.279 to 10.871) J | -0.114 J, -1.1% | no measurable change (p = 0.132) |
  | CPU wake-ups over the refresh window | 1780 (1596 to 1932) wake-ups | 1750 (1658 to 1802) wake-ups | -30 wake-ups, -1.7% | no measurable change (p = 0.310) |
  | Disk writes over the refresh window | 0.046 (0.046 to 1.406) MB | 0.000 (0.000 to 1.702) MB | -0.046 MB | no measurable change (p = 0.260) |
  | Memory during the refresh window (physical footprint) | 128.1 (123.9 to 130.1) MB | 127.2 (105.3 to 131.1) MB | -0.9 MB, -0.7% | no measurable change (p = 0.937) |
  | Allocated memory added by the refreshes | 25.2 (22.8 to 36.9) MB | 21.1 (13.8 to 37.0) MB | -4.2 MB, -16.5% | no measurable change (p = 0.065) |

  No row is higher. The "possibly lower" idle memory is a row the report
  says needs a repeat before it counts, and it is not counted here.

  Disk writes over the refresh window are recorded as no measurable
  change, because the third launch of every turn writes about 1.4 MB on
  either side: 1.406 and 1.406 MB before, 1.360 and 1.702 MB after. In
  the other four launches a side, the before side wrote 0.046 MB every
  time and the after side 0.000 MB every time, which is the cache files
  counted above. The run of 2026-11-13 shows the same large write on
  code without this change, 1.406 MB on one side and up to 1.578 MB on
  the other. What that write is was not looked into.

  The launch rows lean slower on the after side without reaching a
  verdict, and the lean comes from one turn. In the after side's first
  turn, from 14:40 to 14:58 UTC, the three launches took 1.05, 0.91 and
  0.84 s to their first window. In its second turn they took 0.44, 0.76
  and 0.47 s, as the before side's did: 0.47, 0.70 and 0.70 s, then
  0.38, 0.75 and 0.40 s. In that same first turn the Python helper,
  which this change does not touch, was slower too: its second and third
  starts took 0.30 and 0.35 s of CPU against 0.23 to 0.25 s in the other
  three turns. The readings do not show more other work in that turn by
  the four-busiest measure, 209% of a core against 272% and 171% in the
  before side's turns, so what slowed it was not identified.
- Testing: 732 XCTest tests pass with 0 failures, three of them new.
  The first stores a 20-key dictionary, checks that its keys are written
  in sorted order, and checks that five stores of an equal dictionary
  built in the opposite order leave the file's bytes and its file number
  as they were. It then checks that a changed value is written, that a
  value read from its file counts as held, that the file is written
  again after `clearMemoryCache()`, and that a store after a remove
  writes. The second makes a write fail while an older file stays in
  place, and checks that the next store of the same value writes it,
  that the store after that leaves the file alone, and that a file
  deleted by hand or found unreadable is written again. The third runs
  600 stores, removes and reads of three keys from many threads at once
  and checks that each file then holds what memory holds. Each safeguard
  was removed in turn to see a test fail: without the record of failed
  writes, without the check that the file exists, without clearing the
  record after a good write, and without sorted keys, the first or
  second test fails. `checks` and `docs-check` pass. An independent
  review by a reviewer that had not seen the implementation found no
  defect in the comparison or the locking. It found that the first code
  commit, which skipped an unchanged store without looking at the file,
  no longer wrote again a file deleted from outside the app, and would
  not retry a store that followed a write still waiting in the queue if
  that write then failed. The second code commit closes both, and the
  reviewer's second look at it found no defect.
- Known issues:
  - A file changed or damaged from outside the app while it still exists
    is no longer put right at the next snapshot, only when its value
    next changes or the app next reads it and finds it unreadable.
    Before, every snapshot rewrote it. Nothing else in the app or its
    scripts writes to these files. A file that macOS deletes from the
    caches folder to free space is written again at the next snapshot,
    as before.
  - The time recorded inside each file no longer moves forward at every
    snapshot. Nothing in this version reads it. A build from before
    commit `17f29db` dropped a file whose recorded time was over a year
    old, so going back to such a build after a year without a change to
    a value would lose that value from the cache, and it would be
    rebuilt.
  - An unchanged store still costs a block on the file queue, a lock and
    one check that the file exists. This was not timed on its own.
  - The first store of each key after updating to this build rewrites
    its file once, with its keys in sorted order.
  - Not covered by a test: that file work is queued in the order the
    values change. The third test checks only the state at the end and
    would usually still pass without that. Also not covered: two stores
    of the same value both queued before the first one's write fails.
    The second then finds the failure recorded and writes.
- Verdict: retained. The four passes write no cache file where they
  wrote twelve, and no row of the benchmark is higher. The saving is
  small, about 6 KB of file content in four passes, and the benchmark's
  own row for it does not reach a verdict because of the large write
  described above.

### 109: Release the portfolio popover's content when it closes

- What: finding 9 of the
  [Review of the refresh path](#review-of-the-refresh-path-2026-11-13).
  The portfolio item in the menu bar builds new content for its popover
  every time the popover opens, but kept the old content after a close
  until the next open replaced it. Closed, that content was still redrawn
  at every refresh, working out the portfolio summary each time, and its
  chart was still reloaded, with nothing on screen. The popover's
  delegate now releases the content when the popover reports closed,
  if it is not shown again by then: seven added lines in
  `Stockbar/StockStatusBar.swift`. The next open
  builds its content as before. No Rust, dependency or architectural
  change; the change uses AppKit's existing `popoverDidClose` delegate
  call.
- Merged: 2026-11-16, squash commit `7168684`. The merge published
  experimental build 370.16.10 as the prerelease
  `experimental-370.16.10`. Checked after it: the feed's signature and
  the archive's signature are valid, the archive's length matches the
  feed, the unpacked app is build 370.16.10 of 3.7.0, its code signature
  verifies and its executable has no coverage counters. The release's
  tag is on the squash commit; the change adds no name to look for in
  the executable. The build job started four seconds after the merge and
  took about 6 minutes. `main` and `testing` were unchanged.
- What the closed popover does, counted in a trial copy: `0a1ea40` with
  counters added and this change behind a switch, so that one build
  serves both sides. A warm-up launch, then four measured launches in
  turns, content kept and content released. Each opens and closes the
  popover twice, then runs four forced refresh passes 30 s apart. The
  trial copy is never committed. Its patches, scripts and output are
  kept in `build/bench/results/trial-popover-20261113`.

  First run, 2026-11-13 from 20:23 to 20:39 UTC, on battery power with a
  load average of about 8 from other processes:

  | Over the four passes, popover closed | Content kept | Content released |
  | --- | --- | --- |
  | Redraws of the hidden popover | 16 and 16 | 0 and 0 |
  | Portfolio summaries worked out for it | 16 and 16 | 0 and 0 |
  | Time in those summaries | 12.7 and 13.7 ms | none |
  | Chart loads | 16 and 16 | 8 and 8 |
  | Chart models freed of the 2 made by the two opens | 1 and 1 | 2 and 2 |
  | Memory footprint, 2 s after the last pass | 163.58 and 166.25 MB | 141.28 and 150.06 MB |
  | Memory the app holds allocated, same moment | 108.35 and 109.76 MB | 85.72 and 92.66 MB |

  The eight chart loads that remain belong to the main window's own
  chart. The run's CPU, wake-up and power readings overlapped between
  the two sides and showed nothing either way.

  A second run, with the memory read again 30, 60 and 90 s after the
  last pass, was started on 2026-11-16 and stopped during its first
  measured launch, when the owner needed the measuring finished by 16:55
  UTC. It is not used.

  A third run, on 2026-11-16 from 19:52 to 20:14 UTC on mains power,
  used the line as merged, guard included
  (`trial-counters-run3-guarded.patch`), and read the memory 2, 32, 62
  and 92 s after the last pass. The rule fixed before it, the same as
  for the second run: set aside if more than two of its once-a-minute
  readings showed input in the minute before. None of its 21 readings
  did, so it stands; the four busiest processes together averaged 58%
  of a core. In both launches with the content released, the guard
  released it at both closes and kept it at none.

  | Over the four passes, popover closed | Content kept | Content released |
  | --- | --- | --- |
  | Redraws of the hidden popover | 16 and 16 | 0 and 0 |
  | Portfolio summaries worked out for it | 16 and 16 | 0 and 0 |
  | Time in those summaries | 16.6 and 9.7 ms | none |
  | Chart loads | 16 and 16 | 8 and 8 |
  | Chart models freed of the 2 made by the two opens | 1 and 1 | 2 and 2 |
  | Memory the app holds allocated, 2 s after the last pass | 99.26 and 111.98 MB | 83.81 and 85.75 MB |
  | The same, 92 s after the last pass | 97.92 and 110.66 MB | 82.55 and 84.48 MB |

  At each of the four readings, each launch with the content released
  held 13.4 to 28.2 MB less allocated than each launch with it kept.
  Every launch's allocated memory fell by about 1.3 MB between the
  readings at 2 s and 32 s and then held. The memory footprint moved by
  up to 20 MB between readings within one launch, so no figure is taken
  from it. The output is in `run3-guarded-20261116` beside the first
  run's, with `summarise_3.py`. The memory difference still rests on two
  launches each way and is an order of size only.
- Benchmark: the standard comparison of this pull request alone, six
  launches a side, was not run. On 2026-11-16 the owner needed the
  measuring finished by 16:55 UTC and asked for it to be cut down, so
  one shortened comparison covers this pull request and pull request 110
  together. Before `e03cdd5`, after `76dfb6a`: a commit made only for
  the comparison and never pushed, which is `e03cdd5` with both changes
  as they then stood, four lines added here and four added and three
  removed in pull request 110. With `--refresh --runs 2`: four launches
  a side in turns, from 15:50 to 16:42 UTC, macOS 27.2.1, on mains
  power, on a busy Mac and under the two set-aside rules described in
  [pull request 108's entry](#108-leave-a-history-cache-file-alone-when-its-value-has-not-changed).
  No reading inside the turns showed input, and the four busiest
  processes together averaged 60% of a core over the before side's 24
  readings and 61% over the after side's 25, a ratio of 1.01, so the run
  stands. The report flagged no launch. The readings, the rules
  and the scripts are kept beside the results, in
  `build/bench/results/compare-popover-and-session-snapshot-20261116-155018/conditions`.

  With four launches a side the report cannot give a firm verdict: it
  says "possibly" at most, where six a side can say "lower" or "higher".
  The benchmark also never opens the popover, so this pull request's
  line never runs in it. For this pull request the comparison shows that
  the app builds and runs the standard workloads with the change in it,
  and no more. The full comparison followed the merge; it is the next
  item.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 97.8 (93.9 to 103.7) MB | 97.0 (94.1 to 100.5) MB | -0.9 MB, -0.9% | no measurable change (p = 0.686) |
  | Idle memory the app holds allocated | 55.8 (55.5 to 56.2) MB | 55.8 (54.7 to 56.0) MB | +0.0 MB, +0.1% | no measurable change (p = 0.971) |
  | Peak memory, launch and history load | 242.1 (241.2 to 243.3) MB | 244.1 (241.0 to 245.5) MB | +2.0 MB, +0.8% | no measurable change (p = 0.486) |
  | Idle memory growth across the window | 0.3 (0.3 to 0.5) MB | 0.3 (0.0 to 0.5) MB | -0.0 MB, -14.3% | no measurable change (p = 0.657) |
  | Idle CPU | 0.095 (0.083 to 0.100) s/min | 0.091 (0.079 to 0.101) s/min | -0.004 s/min, -4.2% | no measurable change (p = 0.829) |
  | Idle CPU wake-ups | 26 (25 to 30) /min | 26 (26 to 30) /min | +0 /min, +1.9% | no measurable change (p = 0.657) |
  | Idle CPU power | 3.04 (2.91 to 3.28) mW | 3.32 (2.96 to 4.10) mW | +0.28 mW, +9.0% | no measurable change (p = 0.114) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.40 (0.39 to 0.41) s | 0.39 (0.38 to 0.41) s | -0.01 s, -2.5% | no measurable change (p = 0.571) |
  | Launch to history loaded | 0.51 (0.49 to 0.52) s | 0.51 (0.49 to 0.52) s | +0.00 s | no measurable change (p = 1.000) |
  | CPU from launch to the idle window | 1.67 (1.64 to 1.68) s | 1.65 (1.63 to 1.74) s | -0.02 s, -1.5% | no measurable change (p = 0.486) |
  | CPU energy from launch to the idle window | 5.83 (5.72 to 5.88) J | 5.86 (5.76 to 5.96) J | +0.03 J, +0.5% | no measurable change (p = 0.486) |
  | Python helper start to ready, no network | 0.38 (0.24 to 0.53) s | 0.41 (0.23 to 0.54) s | +0.04 s, +9.3% | no measurable change (p = 1.000) |
  | Python helper start, CPU | 0.27 (0.23 to 0.31) s | 0.30 (0.23 to 0.34) s | +0.04 s, +13.2% | no measurable change (p = 0.543) |
  | Python helper memory once started | 71.1 (71.0 to 71.1) MB | 71.2 (71.0 to 71.3) MB | +0.1 MB, +0.1% | no measurable change (p = 0.314) |
  | Refresh passes completed in the refresh window | 4 (4 to 4) passes | 4 (4 to 4) passes | +0 passes | no measurable change (p = 1.000) |
  | CPU over the refresh window | 3.326 (3.266 to 3.360) s | 3.336 (3.320 to 3.344) s | +0.010 s, +0.3% | no measurable change (p = 0.686) |
  | CPU energy over the refresh window | 11.292 (11.039 to 11.485) J | 11.034 (10.412 to 11.363) J | -0.259 J, -2.3% | no measurable change (p = 0.343) |
  | CPU wake-ups over the refresh window | 1883 (1805 to 1967) wake-ups | 1888 (1814 to 1917) wake-ups | +4 wake-ups, +0.2% | no measurable change (p = 0.886) |
  | Disk writes over the refresh window | 0.000 (0.000 to 0.000) MB | 0.000 (0.000 to 0.000) MB | +0.000 MB | no measurable change (p = 1.000) |
  | Memory during the refresh window (physical footprint) | 135.5 (128.5 to 143.7) MB | 140.9 (139.5 to 143.7) MB | +5.4 MB, +4.0% | no measurable change (p = 0.229) |
  | Allocated memory added by the refreshes | 24.6 (21.6 to 25.4) MB | 24.8 (22.9 to 26.1) MB | +0.1 MB, +0.6% | no measurable change (p = 0.543) |

  Every row is no measurable change, and none is marked "possibly". The
  largest lean is memory during the refresh window, 5.4 MB higher at the
  median with the two sides' ranges overlapping: 128.5 to 143.7 MB
  before, 139.5 to 143.7 MB after. Disk writes over the refresh window
  are 0.000 MB on both sides: both carry pull request 108, and with two
  launches a turn the large write of a turn's third launch does not
  occur.
- Full comparison of this pull request and pull request 110 together,
  run on 2026-11-16 after both were merged: before `e03cdd5`, after
  `10129ab`, which is `76dfb6a` with this pull request's guard added and
  this log. Six launches a side with `--refresh`, in turns from 18:35 to
  19:47 UTC, macOS 27.2.1, on mains power, under the same two set-aside
  rules. No reading inside the turns showed input, and the four busiest
  processes together averaged 58% of a core over the before side's 36
  readings and 55% over the after side's 36, a ratio of 1.06, so the run
  stands. The results are in
  `build/bench/results/compare-popover-and-session-snapshot-full-20261116-183408`,
  with the run's log, its readings and the scripts in `conditions`.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 95.2 (86.2 to 97.6) MB | 96.2 (94.4 to 97.9) MB | +1.0 MB, +1.0% | no measurable change (p = 0.290) |
  | Idle memory the app holds allocated | 55.8 (40.0 to 56.0) MB | 55.6 (55.5 to 56.5) MB | -0.1 MB, -0.2% | no measurable change (p = 0.946) |
  | Peak memory, launch and history load | 244.2 (238.8 to 245.9) MB | 246.8 (241.6 to 247.4) MB | +2.6 MB, +1.1% | no measurable change (p = 0.180) |
  | Idle memory growth across the window | 0.5 (0.3 to 0.7) MB | 0.3 (0.3 to 0.6) MB | -0.1 MB, -22.2% | no measurable change (p = 0.610) |
  | Idle CPU | 0.082 (0.073 to 0.102) s/min | 0.097 (0.094 to 0.115) s/min | +0.015 s/min, +17.7% | no measurable change (p = 0.058) |
  | Idle CPU wake-ups | 26 (23 to 31) /min | 24 (24 to 27) /min | -1 /min, -3.9% | no measurable change (p = 0.751) |
  | Idle CPU power | 3.44 (3.00 to 4.38) mW | 2.98 (2.92 to 3.27) mW | -0.45 mW, -13.2% | possibly lower (p = 0.017) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.41 (0.40 to 0.44) s | 0.41 (0.37 to 0.43) s | +0.00 s | no measurable change (p = 0.517) |
  | Launch to history loaded | 0.52 (0.49 to 0.54) s | 0.52 (0.50 to 0.53) s | +0.00 s | no measurable change (p = 0.838) |
  | CPU from launch to the idle window | 1.67 (1.66 to 1.73) s | 1.69 (1.64 to 1.74) s | +0.02 s, +1.2% | no measurable change (p = 0.675) |
  | CPU energy from launch to the idle window | 5.76 (5.61 to 5.99) J | 5.77 (5.56 to 5.95) J | +0.01 J, +0.1% | no measurable change (p = 0.853) |
  | Python helper start to ready, no network | 0.24 (0.23 to 0.95) s | 0.24 (0.23 to 0.50) s | +0.00 s | no measurable change (p = 0.913) |
  | Python helper start, CPU | 0.24 (0.23 to 0.34) s | 0.24 (0.23 to 0.29) s | +0.00 s | no measurable change (p = 1.000) |
  | Python helper memory once started | 71.1 (71.1 to 71.1) MB | 71.1 (71.1 to 71.1) MB | +0.0 MB | no measurable change (p = 1.000) |
  | Refresh passes completed in the refresh window | 4 (4 to 4) passes | 4 (4 to 4) passes | +0 passes | no measurable change (p = 1.000) |
  | CPU over the refresh window | 3.350 (3.246 to 3.386) s | 3.355 (3.320 to 3.432) s | +0.005 s, +0.1% | no measurable change (p = 0.485) |
  | CPU energy over the refresh window | 11.113 (10.894 to 11.159) J | 11.241 (10.879 to 11.634) J | +0.128 J, +1.2% | no measurable change (p = 0.240) |
  | CPU wake-ups over the refresh window | 1870 (1848 to 1904) wake-ups | 1894 (1849 to 1932) wake-ups | +24 wake-ups, +1.3% | no measurable change (p = 0.310) |
  | Disk writes over the refresh window | 0.000 (0.000 to 1.562) MB | 0.000 (0.000 to 1.360) MB | +0.000 MB | no measurable change (p = 0.697) |
  | Memory during the refresh window (physical footprint) | 122.7 (117.7 to 129.4) MB | 122.5 (120.0 to 131.9) MB | -0.2 MB, -0.1% | no measurable change (p = 0.818) |
  | Allocated memory added by the refreshes | 25.5 (23.0 to 43.6) MB | 26.2 (23.2 to 27.3) MB | +0.7 MB, +2.5% | no measurable change (p = 0.818) |

  21 of the 22 rows are no measurable change. Idle CPU power came out
  possibly lower, by 0.45 mW (p = 0.017). Idle CPU leaned the other way,
  17.7% higher (p = 0.058), and the shortened comparison had leaned 0.28
  mW higher on the same row (p = 0.114). A "possibly" needs a repeat
  before it counts, and the benchmark never opens the popover, so the
  row is put down to neither pull request and not claimed. The third
  launch of every turn wrote 1.3 to 1.6 MB in its refresh window on
  both sides, as in earlier comparisons; that was not looked into.

  A rule fixed before the run, and written as the first line of its
  log, called for the two pull requests to be compared separately if
  any row came out "possibly" or firm, before the change was put down to
  either. Neither separate comparison was completed. This pull request
  alone, `e03cdd5` against `7168684` from 20:15 to 21:28 UTC, was set
  aside under the balance rule: the four busiest processes averaged 35%
  of a core over the before side and 75% over the after side, a ratio
  of 2.18. Its repeat was stopped a minute after it started, with no
  launch measured, when the owner asked for the measuring to stop.
  Pull request 110 alone, `7168684` against `10129ab` from 21:29 to
  22:41 UTC, was set aside under the input rule, with input in four
  readings. Every row of both read no measurable change, but set aside
  they are not evidence. Both are labelled and kept in the results
  folder. The owner then dropped both ("Lets drop them").
- The guard: the second code commit releases the content only if the
  popover is not shown when its close is reported, so that a close
  reported late could not empty a popover already open again. An
  independent review found no path in the app by which a close could be
  reported after the next open, but when AppKit reports the close of a
  popover that does not animate is not documented. A standalone check on this Mac, macOS
  27.2.1, with a popover set up as this one is, showed the close reported
  before `performClose` returned in each of four closes, the popover
  reading as not shown inside each report, the content released by the
  guarded line each time, and a reopen with no pause after a close
  showing its content. The check's source is kept with the comparison's
  conditions. The trial's first
  run and the shortened comparison ran before the guard was added; the
  trial's third run and the full comparison ran with it. None of them
  reaches a late close, but in the trial's third run the guard released
  the content at every close, as it should.
- Testing: 732 XCTest tests pass with 0 failures with `experimental`
  merged in and the guard added. `checks` and `docs-check` pass. No test was added: one would have to put a real item
  in the menu bar, and no existing test builds the menu bar controller.
  In the trial's first run every measured launch opened and closed the
  popover twice; with the content released, the two opens drew the
  popover 6 times and made 2 chart models, the same as with the content
  kept, so the second open built its content as the first did. An
  independent review by a reviewer that had not seen the implementation,
  read-only while the comparison ran, found no defect. It confirmed that
  the controller is the delegate of this popover only, that the one
  `show` follows straight after the content is set, that the two other
  reads of the content return early when there is none, and that the
  chart's pending work holds the released content weakly. It could not
  tell from the code when AppKit reports the close, which the guard and
  the check above answer.
- Known issues:
  - Not exercised by hand: reopening the popover after each way it can
    close, which are a click on the menu bar item, a click outside it,
    Escape, a change of Space and the buttons in its footer. The trial
    opened and closed it from code.
  - The memory saving is not a firm figure, as said above.
  - Each per-symbol popover also keeps its content after it closes.
    That is not changed or measured here.
- Verdict: retained. A closed portfolio popover is no longer redrawn: 16
  redraws and 16 summaries over four passes became none, and its second
  chart model is freed, with the guard as merged. The memory saving is an
  order of size. No row of the shortened comparison moved, and none of
  the full comparison moved firmly.

### 110: Leave the positions' prices out of the session's portfolio snapshots

- What: finding 8 of the
  [Review of the refresh path](#review-of-the-refresh-path-2026-11-13).
  Every recorded snapshot appends a portfolio snapshot to a list the app
  keeps for the session, up to 1,800 long, and each one carried a price
  for every position. Nothing reads those prices. The chart's and the
  performance metrics' fallbacks, the trims and the settings view read
  each snapshot's time, total value, total gains and currency, or count
  the list. Each symbol's prices are kept separately, as before. The
  session's snapshots are now recorded with no prices: four lines added
  and three removed in `Stockbar/Data/HistoricalDataManager.swift`. The
  type keeps its field, which snapshots stored by old versions are still
  decoded with and migrated from. No Rust, dependency or architectural
  change.
- Merged: 2026-11-16, squash commit `10129ab`. The merge published
  experimental build 370.16.11 as the prerelease
  `experimental-370.16.11`. Checked after it: the feed's signature and
  the archive's signature are valid, the archive's length, 7,196,399
  bytes, matches the feed, the unpacked app is build 370.16.11 of 3.7.0,
  its code signature verifies and its executable has no coverage
  counters. The release's tag is on the squash commit. `main` and
  `testing` were unchanged. The merged commit differs from `76dfb6a`,
  which the shortened comparison measured, only in pull request 109's
  guard and this log.
- The size of the list, measured outside the app. A standalone program
  using the app's own two types built the list at its full length of
  1,800 snapshots, with and without the prices. Two runs gave the same
  figures. The program and its output are kept in
  `build/bench/results/trial-session-snapshot-20261113`.

  | Positions | 1,800 snapshots with prices | Without | Less per snapshot |
  | --- | --- | --- | --- |
  | 11 | 2,500,384 bytes | 196,384 bytes | 1,280 bytes |
  | 30 | 4,804,096 bytes | 196,096 bytes | 2,560 bytes |
  | 60 | 9,411,584 bytes | 195,584 bytes | 5,120 bytes |

  At the default interval of five minutes the app records 12 snapshots
  an hour, so the list is full after 150 hours of recording. With 11
  positions the saving grows by about 15 KB for each hour the app runs,
  to about 2.3 MB. These are sizes of the data, not a measurement of the
  running app's memory.
- Benchmark: the standard comparison of this pull request alone, six
  launches a side, was not run. It shares the shortened comparison
  recorded in
  [pull request 109's entry](#109-release-the-portfolio-popovers-content-when-it-closes),
  whose table is there: before `e03cdd5`, after the local-only commit
  `76dfb6a` holding this change and pull request 109's, four launches a
  side with `--refresh --runs 2`, on 2026-11-16 from 15:50 to 16:42 UTC.
  The benchmark records four snapshots a launch, so for this change it
  is a check for regressions, not the evidence of the saving. With four
  launches a side it cannot give a firm verdict. Every row of it is no
  measurable change, and none is marked "possibly". The full comparison
  of both, six launches a side on the merged commit, followed the same
  day and is in pull request 109's entry. No row of it moved firmly, and
  its one "possibly", idle CPU power lower, is put down to neither pull
  request.
- Testing: 732 XCTest tests pass with 0 failures with `experimental`
  merged in, pull request 109 included. `checks` and `docs-check` pass. No test was added: a test would have to record
  through the app's shared history manager, which also queues writes to
  the shared store. An independent review by a reviewer that had not
  seen the implementation, read-only while the comparison ran, found no
  defect. It confirmed that every read of the session's list takes the
  time, the totals, the currency or the count; that nothing encodes or
  stores the list; that the one reader of a portfolio snapshot's prices,
  the migration of snapshots stored by old versions, sees only data
  those versions wrote; that export and settings transfer do not include
  the list; and that no test builds or records one.
- Known issues:
  - The saving is worked out from the sizes of the types. It was not
    measured in the running app.
  - Code added later that wanted each position's price from this list
    would find none. Each symbol's own price list still has them.
- Verdict: retained. The session's list no longer holds a price for
  every position in every snapshot, which nothing read: about 2.3 MB less
  once the list is full with 11 positions, by the sizes of the types. No
  row of the shortened comparison moved, and none of the full comparison
  moved firmly.

### 112: Record the full comparison of pull requests 109 and 110 and the end of the overhaul

- What: the full comparison of pull requests 109 and 110 and the
  separate comparisons that were dropped, in pull request 109's entry;
  the popover trial's third run, with the guard as merged; the merge
  line of pull request 110; the owner's decisions of 2026-11-16 and
  2026-11-17 under [Where things stand](#where-things-stand), with the
  milestone table and the plan paragraph brought up to date; and a row
  in "Who did what". Only this file changes.
- Merged: 2026-11-17, squash commit `be1bf79`. The merge published
  experimental build 370.16.12, whose app is that of 370.16.11.
- Benchmark: no before/after run. No file that goes into the app changes
  (nothing under `Stockbar/`, `StockbarTests/` or `Stockbar.xcodeproj`),
  so before, `10129ab`, and after build the same app. What this pull
  request records are the measurements made on 2026-11-16, each kept in
  the results folder it names.
- Testing: `docs-check` passes on this pull request's branch. The full
  test suite and `checks` run on the merged commit before the promotion
  to `testing`.
- Review: read by its author, with each figure checked again against the
  result files it comes from. No independent review, for a record of
  measurements that changes no code.
- Known issues: the third launch of every comparison turn writes 1.3 to
  1.6 MB in its refresh window, on both sides; not looked into.
- Verdict: retained.

### 114: Bring `testing` back into `experimental` and record the second promotion

- What: the [second promotion](#second-promotion-to-testing-2026-11-17)
  recorded, with "Where things stand", the milestone table and the merge
  line of pull request 112 brought up to date, and a row in "Who did
  what". The branch starts from `testing` at `78c886b`, the promotion's
  merge commit, so merging it brings that commit into `experimental`.
  Only this file changes.
- Merged: with a merge commit, the exception to the squash rule described
  under [How this branch works](#how-this-branch-works). Its merge record
  is on the pull request, since no later pull request into `experimental`
  is planned.
- Benchmark: no before/after run. `78c886b` has the files of `be1bf79`,
  and this pull request changes only this file, so the app is the same.
- Testing: `docs-check` passes on this branch. The tests of the promoted
  commit are under the second promotion.
- Review: read by its author, with each figure checked against the
  published build and the pull requests it names.
- Known issues: none known.
- Verdict: retained.

### 134: Let the acceptance copy reach a Folync on this Mac

- What: in an acceptance run, a Folync request is let through when its
  endpoint is on this Mac (`127.0.0.1`, `localhost` or `::1`). Everything
  else stays refused. The owner approved it on 2026-11-19. Until now
  `StockbarProviderAccessPolicy` refused every provider in an acceptance
  run, so the acceptance copy could never read the Folync stand-in on
  loopback that `script/run_folync_acceptance.sh` and the bootstrap
  require. The redesign's Folync pages could not be tried on made-up data.

  `StockbarAcceptanceRuntime` gains `loopbackFolyncAllowed`. It is true
  only for an explicit acceptance run, and false for the automatic XCTest
  isolation and for a normal run. The policy gains
  `authorize(_:endpoint:)`. It allows everything when live requests are
  allowed. Otherwise it allows only `.folync`, with the exception on, to
  an `http` or `https` URL whose host is exactly one of the three; the
  host is compared whole, with no name lookup. `authorize(_:)` without an
  endpoint behaves as before. `FolyncPortfolioSource` and
  `FolyncSupplementalCoordinator` pass their base URL on every request,
  before the endpoint check and before any network use. Changing the
  address inside the acceptance copy to another machine is therefore still
  refused. These are the only two Folync calls to the policy, and no other
  provider's gate changes. The preflight report gains
  `loopbackFolyncAllowed`, so the evidence shows the exception, and
  `Docs/Development.md` describes it.
- Merged: 2026-11-20, squash commit `5fa923b`. The merge published
  experimental build 382.3.3 as the prerelease `experimental-382.3.3`.
  Checked after it: both jobs of the release workflow succeeded and the
  prerelease is listed. The published archive was not downloaded or
  opened.
- Benchmark: before `01d4768`, after `7aba2f7`, the standard comparison,
  six launches a side in turns, run twice on 2026-11-20, on macOS 27.2.1
  and mains power, with the screen unlocked and the display awake. After
  the repeat no row shows a measurable change. This pull request names no
  row: the benchmark's launches are acceptance runs with no Folync set
  up, so they never reach the exception.

  Neither run was measured on a quiet Mac. The comparison was scheduled
  for 02:30 UTC and did not run then. The Mac restarted at 08:35 UTC and
  the owner said "Try now" at about 08:55. Another session on the Mac was
  running a different project's simulator tests: one was running at
  08:55, and a wait for a quiet Mac passed at 09:06 only for the next to
  begin within the minute. No start time was going to avoid them, so the
  first run started at once under rules written into its script before
  it began. Two are the
  rules of 2026-11-16, which say when a run is set aside and repeated
  (see
  [pull request 108's entry](#108-leave-a-history-cache-file-alone-when-its-value-has-not-changed)).
  The third is new and decides the merge. A sample every ten seconds
  notes whether another project's `xcodebuild` is present, and a measured
  launch with one or more such samples counts as overlapped. With any
  launch overlapped, the pull request is not merged on that run without
  the owner's word or a repeat with the other session paused. The samples
  show that such a process was present, not how hard it was working; the
  load average and the four busiest processes below are the measure of
  that.

  First run, turns from 09:14 to 09:47 UTC. No reading inside the turns
  showed input. The four busiest processes together averaged 260% of a
  core over the before side's 17 readings and 313% over the after side's
  16, a ratio of 1.20, so the run stands. All twelve measured launches
  were overlapped. The load average at the once-a-minute readings inside
  the turns ran from 5.8 to 48.8. `StorageManagementService` and
  `ApplicationsStorageExtension`, two system processes, were among the
  four busiest in 31 of the run's 37 readings, beside the other project's
  compiler, simulator app and test runner in others. The report flagged
  no launch. One row is marked: idle CPU
  wake-ups, possibly lower.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 88.9 (87.1 to 94.8) MB | 90.8 (84.8 to 93.4) MB | +1.9 MB, +2.1% | no measurable change (p = 1.000) |
  | Idle memory the app holds allocated | 49.1 (40.0 to 51.8) MB | 49.5 (40.0 to 51.7) MB | +0.4 MB, +0.8% | no measurable change (p = 0.859) |
  | Peak memory, launch and history load | 238.6 (234.9 to 256.9) MB | 247.7 (237.2 to 252.3) MB | +9.1 MB, +3.8% | no measurable change (p = 0.180) |
  | Idle memory growth across the window | -0.1 (-2.2 to 0.0) MB | 0.0 (-6.5 to 0.1) MB | +0.1 MB, -100.0% | no measurable change (p = 0.364) |
  | Idle CPU | 0.091 (0.075 to 0.104) s/min | 0.088 (0.079 to 0.097) s/min | -0.003 s/min, -2.7% | no measurable change (p = 0.788) |
  | Idle CPU wake-ups | 28 (26 to 29) /min | 24 (22 to 28) /min | -4 /min, -12.5% | possibly lower (p = 0.019) |
  | Idle CPU power | 4.64 (4.25 to 5.22) mW | 5.02 (4.44 to 5.28) mW | +0.38 mW, +8.2% | no measurable change (p = 0.331) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 1.06 (0.99 to 1.35) s | 1.04 (0.96 to 1.88) s | -0.02 s, -1.9% | no measurable change (p = 0.669) |
  | Launch to history loaded | 1.11 (1.01 to 1.34) s | 1.03 (0.93 to 1.86) s | -0.08 s, -7.2% | no measurable change (p = 0.457) |
  | CPU from launch to the idle window | 2.25 (2.11 to 2.75) s | 2.18 (2.03 to 3.46) s | -0.07 s, -2.9% | no measurable change (p = 0.485) |
  | CPU energy from launch to the idle window | 6.31 (5.26 to 6.69) J | 6.39 (4.47 to 6.64) J | +0.08 J, +1.2% | no measurable change (p = 0.937) |
  | Python helper start to ready, no network | 0.34 (0.30 to 1.03) s | 0.31 (0.29 to 1.02) s | -0.03 s, -8.8% | no measurable change (p = 0.247) |
  | Python helper start, CPU | 0.33 (0.30 to 0.45) s | 0.31 (0.28 to 0.45) s | -0.02 s, -7.5% | no measurable change (p = 0.411) |
  | Python helper memory once started | 71.2 (70.4 to 71.4) MB | 71.2 (71.1 to 71.4) MB | -0.0 MB, -0.1% | no measurable change (p = 0.961) |

  Repeat, for that row, turns from 10:08 to 10:41 UTC. A wait of twenty
  minutes for a quiet Mac found another project's `xcodebuild` at 39 of
  its 40 checks, so the repeat started without one, under the same
  rules. No reading inside the turns showed input. The four busiest
  together averaged 228% of a core over the before side's 16 readings
  and 276% over the after side's 16, a ratio of 1.21, so it stands.
  Again all twelve measured launches were overlapped. The load ran from
  5.1 to 41.1, and the same two system processes were among the four
  busiest in 32 of 33 readings. The report flagged no launch and marks
  no row. Idle CPU wake-ups are 26 a minute on both sides.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 93.3 (90.4 to 95.6) MB | 92.7 (85.3 to 95.8) MB | -0.7 MB, -0.7% | no measurable change (p = 0.699) |
  | Idle memory the app holds allocated | 50.4 (48.1 to 51.9) MB | 49.6 (46.1 to 50.6) MB | -0.8 MB, -1.6% | no measurable change (p = 0.197) |
  | Peak memory, launch and history load | 248.2 (241.7 to 257.8) MB | 245.4 (238.0 to 261.1) MB | -2.8 MB, -1.1% | no measurable change (p = 0.818) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.1) MB | 0.0 (-3.9 to 0.0) MB | +0.0 MB | no measurable change (p = 0.273) |
  | Idle CPU | 0.084 (0.074 to 0.097) s/min | 0.079 (0.070 to 0.091) s/min | -0.005 s/min, -6.0% | no measurable change (p = 0.457) |
  | Idle CPU wake-ups | 26 (24 to 31) /min | 26 (22 to 28) /min | -0 /min, -1.9% | no measurable change (p = 0.662) |
  | Idle CPU power | 4.25 (3.79 to 4.61) mW | 4.51 (3.89 to 4.84) mW | +0.26 mW, +6.1% | no measurable change (p = 0.394) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.83 (0.62 to 1.05) s | 0.91 (0.56 to 1.04) s | +0.08 s, +9.6% | no measurable change (p = 0.937) |
  | Launch to history loaded | 0.89 (0.61 to 1.01) s | 0.90 (0.66 to 1.02) s | +0.01 s, +1.7% | no measurable change (p = 0.734) |
  | CPU from launch to the idle window | 2.06 (1.74 to 2.19) s | 2.12 (1.87 to 2.17) s | +0.06 s, +2.9% | no measurable change (p = 0.677) |
  | CPU energy from launch to the idle window | 5.80 (4.52 to 6.58) J | 5.91 (5.50 to 6.49) J | +0.11 J, +1.8% | no measurable change (p = 0.818) |
  | Python helper start to ready, no network | 0.60 (0.33 to 1.09) s | 0.36 (0.29 to 1.00) s | -0.24 s, -40.0% | no measurable change (p = 0.329) |
  | Python helper start, CPU | 0.43 (0.32 to 0.58) s | 0.34 (0.29 to 0.45) s | -0.09 s, -20.7% | no measurable change (p = 0.102) |
  | Python helper memory once started | 71.3 (70.3 to 71.4) MB | 71.2 (71.1 to 71.4) MB | -0.0 MB, -0.1% | no measurable change (p = 0.920) |

  The "possibly lower" row did not repeat, so it does not count. The
  conditions limit what the two tables show. Their ranges are wide: in
  the first run one launch on the after side took 1.88 s to its first
  window where the side's median was 1.04 s. A change smaller than that
  spread would not show, and these figures are not set beside those of
  other days. What they show is that the app builds and runs the standard
  launches with the change in it, and that nothing moved by more than a
  busy Mac's noise. The readings, the samples, the rules and the scripts
  are kept beside the results, in
  `build/bench/results/compare-pr134-20261120-091103/conditions` and
  `build/bench/results/compare-pr134-repeat-20261120-100818/conditions`.
- Testing, on macOS 27.2.1 and Xcode 27.2: 754 XCTest tests with 0
  failures. Twelve are new. Eight in `StockbarProviderAccessPolicyTests`
  cover the policy: the three loopback forms allowed; ten other forms
  refused, among them `127.0.0.1.example.com`, `localhost.example.com`,
  `http://127.0.0.1@example.com/`, an address on the local network, a URL
  with no host and schemes other than HTTP; the other three providers
  refused even on loopback; Folync without an endpoint still refused; the
  automatic XCTest runtime refused; a normal run allowed everything. Four
  in `FolyncPortfolioSourceTests` go through a stubbed `URLSession`. With
  the policy of an explicit acceptance run, both the source and the
  supplemental coordinator reach a stub at `http://127.0.0.1:49152`. For
  addresses elsewhere neither sends a request, and both fail with
  `disabledForAcceptance(.folync)`. The source's own endpoint check refuses
  plain HTTP on the local network before the policy is asked, so its test
  uses HTTPS addresses to reach the policy. The runtime and preflight tests
  assert the new field.

  The tests were shown to fail on broken code. With `isLoopback` returning
  true for every URL, four tests failed. With the exception granted without
  the runtime's flag, the two tests of a policy without it failed. Both
  mutations were then removed. The policy's initialiser was tidied after
  them, in lines neither mutation touched, and everything below was run
  again on the result.

  `checks`, `docs-check` and `build-release` pass, and so do 92 script
  tests. 70 Python helper tests pass, none skipped. They ran with Homebrew
  Python 3.15.2, which has no yfinance, rather than the app's own
  environment, which this work did not touch; CI uses Python 3.13 with the
  lock file. No Python changed.

  An acceptance copy was built from this branch and run against
  `build/design/acceptance/stub_folync.py`, a stand-in kept in the
  untracked `build/` folder, for nearly three minutes, with
  debug logging, and counted after it had stopped. The stub answered 32
  requests, all with 200: the snapshot seven times, the portfolio history
  ten, capabilities six, FX five and benchmarks four. The app logged seven
  Folync polls with success and none without, and no
  `provider_access_denied` line, warning or error. A poll reports success
  only after a 304, or a 200 whose snapshot was decoded and applied, and
  every answer was a 200; there is no log line of its own for applying. The app also wrote the snapshot cache and five route
  caches, which it does only after a response passes its checks. The
  preflight evidence held `liveProviderRequestsAllowed` false and
  `loopbackFolyncAllowed` true. The session lead then ran the copy again
  and looked at its window: the Overview and Holdings showed the stand-in's
  made-up portfolio, labelled as a Folync portfolio.
- Review: the session lead (Fable 5.2) read the policy, both call sites
  and the tests against the specification. Written by an Opus subagent from
  that specification. No independent second review.
- Known issues:
  - No launch of either comparison was measured on a quiet Mac, as set out
    above.
  - The stand-in answers 200 with a new body every time, so the app's 304
    path was not exercised in the run.
  - A manifest with `http://[::1]:<port>` passes the launcher, the
    bootstrap and the new policy, but not `FolyncEndpointPolicy`, which
    allows plain HTTP only to `localhost` and `127.0.0.1`. Such a run would
    still fail, now with the HTTPS message. Not changed here.
  - `URLSession` follows redirects, and nothing asks the policy about a
    redirect's target. A Folync on this Mac that redirected elsewhere would
    be followed. The stand-in never redirects, and a normal run behaves the
    same way. Not changed here.
- Verdict: retained. No row shows a measurable change after the repeat,
  and none was expected to move. Another project's `xcodebuild` was
  present during every measured launch, and the rule written before the
  first launch left the merge to the owner in that case. Told so, with
  the tables and the conditions, the owner said "go on" on 2026-11-20.

### 135: Read Folync's dividends, trade analysis and transactions

- What: the groundwork for the redesign's Income, Activity and Trades
  pages. Stockbar can now read three Folync routes it did not call:
  dividends, trade analysis and transactions. Nothing on screen changes,
  and nothing calls the routes yet; the pages come in later pull
  requests.

  Stored settings first. `FolyncSupplementalSettings` decoded with the
  synthesized decoder, so adding a field would have made settings stored
  by an older build fail to decode, and the Folync configuration would
  have fallen back to everything off. It now decodes field by field. A
  missing existing field is off. Three new fields, `dividends`,
  `tradeAnalysis` and `transactions`, are on when missing, because these
  routes are fetched only when their page is opened; a new connection
  takes each from Folync's capabilities. No Settings switch shows them
  yet. The three routes have their own enum, `FolyncLedgerRoute`, because
  the Settings screen and the acceptance preflight list every case of
  `FolyncSupplementalRoute`.

  Folync's capabilities gain three optional resources. A capabilities
  document saved by an older build has none of them, and confirming it
  with a 304 would have hidden the routes for good, so documents are now
  saved under a new cache key. The old document is used only while Folync
  does not answer, and its ETag is never sent.

  Models for the three responses are in `Services/FolyncLedgerData.swift`.
  Unknown keys are ignored, a figure Folync sends as null stays unknown
  and is never read as zero, and an enum value this build does not know
  is kept. Each route follows the portfolio-history route: the settings,
  scope and capability gates, the saved copy with its ETag, 304, schema
  version 2, a stale copy when Folync does not answer, and "could not
  reach" told apart from "not available".

  Folync rebuilds its whole report for each of these routes, does not
  queue them, and a later page costs as much as the first. So one object,
  `FolyncLedgerFetchPolicy`, sits in front of all three. Requests take
  turns, one at a time across the three routes, and callers asking for
  the same thing share one request. A first page is reused for five
  minutes with no request, unless the caller asks for a refresh. Later
  pages come only from an explicit "load more" and are kept nowhere. A
  409, a refused cursor or a changed collection revision restarts from
  page one. A request still waiting its turn is not made once every
  caller waiting for it has been cancelled. Date parameters are calendar
  days, not instants, so a day chosen in the user's time zone is the day
  asked for.
- Merged: 2026-11-20, squash commit `e04e21b`. The merge published
  experimental build 382.3.4 as the prerelease `experimental-382.3.4`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run. The owner parked the benchmarks on
  2026-11-20, see [Where things stand](#where-things-stand), and the
  other project's work was running while this was built. All fifteen rows
  of the standard set are therefore not measured for this pull request,
  and none is carried over from another run. Expected, not measured: no
  row moves, because nothing calls the new routes and the benchmark's
  launches set up no Folync. It is covered by the phase's comparison in
  the first quiet window.
- Testing, on macOS 27.2.1 and Xcode 27.2: 789 XCTest tests with 0
  failures. 35 are new: 29 in `FolyncPortfolioSourceTests` and 6 in
  `Trading212BrokerSyncTests`. They go through a stubbed `URLSession` and
  cover, for the three routes: page one from each route's own path; the
  query parameter names and limits; 304; a body that does not decode and
  a schema other than 2; offline with and without a saved copy; 502 and
  503 against 500 and 404; the route or Folync switched off; the
  capability absent, unsupported and not ready; the shared backoff after
  401 and 429; no request when the provider policy refuses; an invalid
  scope; saved copies kept apart by route, scope and query; load more;
  the three restarts; a 400 that is not about the cursor; reuse inside
  five minutes and a request after it; a failed or stale answer not
  reused; requests never overlapping across routes; identical concurrent
  calls sharing one request; a refresh not joining a request that may
  reuse; a queued request dropped when its callers are cancelled, and
  made when one still waits; no request for a caller already cancelled;
  kept pages forgotten after the window; a London summer midnight asking
  for the right day. The settings tests decode the exact JSON an older
  build stored, a blob with keys missing and a round trip. The
  capabilities tests decode with and without the new resources.

  The tests were shown to fail on broken code, each breakage applied,
  run and removed. By the worker, ten: the reuse window ignored (seven
  tests failed); a null figure read as zero (one); the one-at-a-time gate
  removed (two); the 409 restart removed (one); the revision restart
  removed (one); sharing removed (two); a 404 returning the saved copy
  (one); the old capabilities ETag sent (one); a missing new setting
  decoded as off (two); the provider check skipped (one). The first try
  at removing the gate was caught only by the policy's own test, because
  the stub answered on one thread, so the stub was changed to hold
  requests open together. By the session lead, four, on the lead's own
  changes: the dropped-request check removed, the forgetting removed, the
  check for a caller already cancelled removed, and the time zone
  ignored. One test failed for each.

  `checks`, `docs-check` and `build-release` pass on the final commit.
  70 Python helper tests and 92 script tests passed on the worker's last
  commit; the lead's commit after it changed Swift and one document, no
  Python.

  Not run: the app. Nothing calls the routes, so there is nothing to see,
  and neither a real Folync nor the stand-in used for the acceptance copy
  serves them to this code yet.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read the fetch policy, the
  routes, the settings and capabilities changes and the query types in
  full, the models in outline, and checked the page, the dividend event
  and the dividend summary against Folync's client contract. It did not
  read every test, only their names and the policy's. It changed three
  things: the dropped request and the caller already cancelled, the
  forgetting of kept pages, and the calendar-day type. No independent
  second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - None of this has been tried against a real Folync. Two behaviours
    follow the written contract alone: which 400 counts as a refused
    cursor, and each response's scope matching the scope asked for.
  - A stored configuration with no supplemental settings at all still
    reads as everything off, the three new routes included, until a
    Settings switch exists for them.
  - The shapes shared with the existing routes are strict. A quality or
    scope kind this build does not know still fails the whole answer, as
    it does for the snapshot and the history.
  - Parts of the dividends answer that no planned page uses are not
    decoded: liability coverage, corporate cash flows, undated
    announcements, per-source coverage and forecast detail. From a
    transaction, the exchange-rate basis and the provenance.
  - A cancelled caller is not released at once. It waits until its
    request's turn comes, and only then learns that no request was made.
  - A server whose capabilities list none of the three routes is asked
    for its capabilities in full once after the update, then confirmed
    with 304 as before.
- Verdict: retained, with its benchmark owed. The owner chose on
  2026-11-20 to merge on the local checks and the review, and to measure
  each phase in the first quiet window.

### 136: Ask Yahoo for instrument type, dividend dates and earnings dates

- What: the groundwork for the redesign's Calendar, its reminders, the
  Funds group in Allocation and an income estimate for local portfolios.
  Nothing on screen changes, and nothing calls the new service yet.

  A new helper script, `get_instrument_events.py`, asks Yahoo through the
  pinned yfinance for each symbol's instrument type, ex-dividend date,
  pay date, earnings date or range, and the dividends of the last twelve
  months. A field Yahoo does not give is null, never a guess and never
  zero. A date already past is returned as it is; the app decides with
  the clock what is still to come. Dividends quoted in pence are turned
  into pounds by the rule prices already use (`uses_pence_quotes` in
  `get_ohlc_data.py`). One symbol failing does not fail the others, and a
  rate-limit answer stops the run and is reported as its own error.
  yfinance logs most request failures instead of raising them, so the
  script reads its log for each symbol and reports a timeout or a lost
  connection as an error, not as a symbol with nothing. While it runs,
  the script reads the process clock in UTC: yfinance 1.8.0 makes Yahoo's
  calendar dates with `datetime.fromtimestamp`, in the local zone, and a
  date stamped at midnight UTC would come out a day early west of UTC.

  The script is listed everywhere the helper scripts are listed: the
  worker's whitelist, the Swift pool's copy of it and the compile line in
  `script/develop.sh`. A new test fails if any of the three misses a
  script.

  `InstrumentEventsService` runs the script only when
  `StockbarProviderAccessPolicy` allows the Python bridge, so never in an
  acceptance run or under XCTest isolation. It keeps each symbol's answer
  for a day under Application Support, written atomically, and removes
  copies older than thirty days. Everything missing or expired is asked
  for in one run, and callers asking at the same time share it. When
  Yahoo does not answer it returns the saved copy, however old, marked
  stale. After a rate-limit answer it makes no run for an hour, forced or
  not. A symbol Yahoo has nothing for is not asked for again that day
  unless a refresh is forced. No timer and no polling.
- Merged: 2026-11-20, squash commit `16f1a3d`. The merge published
  experimental build 382.3.5 as the prerelease `experimental-382.3.5`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run. The owner parked the benchmarks on
  2026-11-20 until the other project's work on this Mac has been idle for
  more than 20 minutes. All fifteen rows of the standard set are
  therefore not measured for this pull request, and none is carried over
  from another run. Expected, not measured: no row moves, because nothing
  calls the service. The three Python rows start the worker, whose list
  of scripts gains one name; what it loads at start is unchanged. It is
  covered by the next comparison run under the rule of 2026-11-20.
- Testing, on macOS 27.2.1 and Xcode 27.2: 766 XCTest tests with 0
  failures. Twelve are new, in `OHLCFetchServiceTests.swift`, with the
  process runner stubbed and the clock injected: every field decoded and
  null kept as nil; one unreadable entry not failing the others; a saved
  copy used inside a day and refreshed after it; several symbols in one
  run, de-duplicated; callers at the same time sharing a run; a stale
  copy when the run fails; no run when the provider policy refuses; the
  hour's pause after a rate limit, for one symbol and for the whole run,
  forced or not; a forced refresh inside the day; a symbol Yahoo does not
  know left alone that day; the thirty-day clean-up.

  103 Python helper tests pass on the app's own environment (Python
  3.13, with yfinance 1.8.0 and pandas importable), none skipped. 33 are
  new, all with a fake `yf` and no request: a share with everything; a
  London-like share with a past ex-dividend date, no pay date and pence;
  a fund with no calendar; pounds not divided again; a missing currency;
  dividends with a currency of their own; unusable amounts left out; the
  twelve-month boundary and a leap day; an earnings range; `NaT`, `NaN`,
  `None`, lists and zoned timestamps; an unknown symbol; an exception for
  one symbol among several; a failure yfinance only logged; a rate limit
  with and without its exception type; spacing between symbols; the time
  budget; the command line; calendar dates read in UTC on a Mac set to
  Los Angeles, with the zone put back; and the registration test above.

  The tests were shown to fail on broken code, each breakage applied, run
  and removed. By the worker, six: pence not converted (three tests
  failed); a missing date turned into today's date (six); a rate limit
  not stopping the run (one); failures yfinance only logged ignored
  (one); the day-long reuse ignored (six); the provider check skipped
  (one). The four Python breakages were run against the script's first
  version; its last commit did not touch the lines they altered. By the
  session lead, two, on the lead's own changes: the clock left in the
  local zone, and unknown symbols not remembered. One test failed for
  each.

  `checks`, `docs-check` and `build-release` pass on the final commit,
  and so do 92 script tests.

  After pull request 135 was merged this branch was brought up to date
  with it, and everything was run again on the two together: 801 XCTest
  tests with 0 failures, 103 Python helper tests and 92 script tests,
  with `checks`, `docs-check` and `build-release`.

  No request was made to Yahoo in building or testing this. What is
  known of Yahoo's real answers is the one-off check of 2026-11-19: a US
  share gave every date and twelve months of dividends; a London share
  gave a past ex-dividend date, no pay date and dividends in pence; a
  London-listed fund gave no calendar, only its dividend history; the
  instrument type came back for all three.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read the script and the
  service in full, and the tests' harness and names, and read in yfinance
  1.8.0's own source how it makes the calendar dates. It changed two
  things: the UTC clock while the script runs, and the day's memory of
  symbols Yahoo does not know. No independent second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - Nothing here has been tried against Yahoo. In particular it is not
    known whether a fund with no calendar arrives as a logged "not
    found", which the script reads as no calendar, or as an error it
    would report as a failure.
  - An earnings time is turned into a UTC date. That is the exchange's
    own date for US and London listings, but can be a day off for an
    exchange far ahead of UTC.
  - The UTC setting applies to the whole helper process while the script
    runs. A request left running past its symbol's deadline may finish
    after the zone is put back; its answer is not used.
  - The hour's pause after a rate limit and the memory of unknown
    symbols are held in memory and do not survive a relaunch.
  - Symbols go to Yahoo exactly as given. The aliases and the `.LON`
    handling of `get_stock_data.py` are not applied.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20
  under [How this branch works](#how-this-branch-works).

### 137: Give every surface in the main window the Glass look

- What: the first visible pull request of the redesign. Every surface in
  the main window takes the Glass look from one place,
  `Views/StockbarDesign.swift`: cards, inset panels, the metric strip and
  tiles, notices, empty states, pills and badges, rows, chart callouts and
  the range switches inside pages. Pages, content, layout and behaviour
  are the same. The window, the sidebar, the popover and the Overview's
  new content are later pull requests.

  Tokens have a light and a dark value: the card's fill, stroke and top
  highlight, the hover and selected fills, and gain and loss colours that
  are deeper in light mode so figures stay readable on a light card. Every
  surface is solid under Reduce Transparency and has a stronger stroke and
  fill under Increase Contrast. Nothing here uses a glass or blur API, so
  nothing needs an availability check.

  The colours that already existed were not changed where they are used
  outside the main window. The popover, the menu-bar price chart and chart
  series keep the system green and red through the unchanged `signed()`;
  main-window figures use the new `signedOnSurface`. The popover's own
  card and hover fills were renamed with their values kept.

  Risk and Allocation no longer draw their own panels. The charts page's
  panels, the attribution sheet, the Holdings table, the Alerts rows, the
  Diagnostics log and sheets and the Settings previews all use named
  surfaces. Holdings and Backups show their three tiles as one strip.

  The range switch is a new capsule control, `StockbarSegmentedControl`.
  It replaces the native segmented picker for the ranges and modes inside
  pages: the Overview, the charts page's time range and its line or
  candlestick style, Risk, Allocation, the attribution sheet and the
  Settings tab bar. The annotation editor's picker, the Theme picker in
  the Settings form and the popover's picker stay native. The left and
  right arrows step the selection and stop at either end, and with Reduce
  Motion on the selection changes without animating.

  `Scripts/validate_invariants.sh` now fails when a view outside the
  design file draws a surface from a raw system colour or material. A line
  that must keep its colour ends with a comment giving the reason. Three
  lines do: the exported chart image's white page, the popover's notice,
  which waits for the popover's own pull request, and a grey status dot.

  The acceptance copy gains launch options, read once and only in an
  explicit acceptance run, by the same gate as the loopback exception of
  pull request 134: the appearance, the page the window opens on, the
  preferred currency and the minimum window size. A normal run and the
  automatic XCTest isolation ignore them. The preflight evidence records
  the options applied, and `Docs/Development.md` describes them. Every
  later page of the redesign is checked with them.
- Merged: 2026-11-20, squash commit `fe59b8d`. The merge published
  experimental build 382.3.6 as the prerelease `experimental-382.3.6`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20 under
  [How this branch works](#how-this-branch-works). Unlike the two before
  it, this pull request changes code the benchmark runs: the main window
  the launches open draws its surfaces differently. No row is named, and
  none is expected to move by much, but that is not measured. It is
  covered by the comparison run after Phase A's last pull request.
- Testing, on macOS 27.2.1 and Xcode 27.2: 814 XCTest tests with 0
  failures. Thirteen are new: five on the surfaces (solid under Reduce
  Transparency, stronger under Increase Contrast, the card's values in
  each scheme, a hosted card honouring the settings it is drawn under, and
  the gain and loss colours); two on the range switch (the arrow keys, and
  what it exposes to assistive technology); five on the launch options (an
  explicit acceptance run reads each one, a normal run and the XCTest
  isolation ignore them, each unknown value is dropped on its own, and
  applying writes only the settings named); one on the preflight evidence.
  95 script tests pass, three new for the invariant check: thirteen
  made-up direct uses all caught, named surfaces and an allowed line
  passing, and an allow comment with no reason failing. 103 Python helper
  tests pass. `checks`, `docs-check` and `build-release` pass on the final
  commit. The session lead ran the XCTest suite and `checks` again on that
  commit.

  The tests were shown to fail on broken code, each breakage applied, run
  and removed: the launch options gated on the root alone (the XCTest
  isolation test failed); Reduce Transparency ignored (two tests failed);
  the arrow keys allowed to wrap (one); materials dropped from the
  invariant check (one).

  On screen: the worker ran the acceptance copy against the stand-in with
  a made-up portfolio and took 37 captures, one window at a time, of every
  page and every Settings tab in dark and light, the Overview at the
  minimum window size, the charts page with a holding selected and with
  its export options open, and the attribution sheet. Two things were
  fixed after looking. In light mode a white card almost disappeared on
  the white page and its top highlight erased its edge, so light cards got
  a firmer outline and a soft shadow and lost the highlight. The chart
  style switch cut "Candlestick" short and now sizes to its labels. The
  dark captures were taken before the first of those fixes, which does not
  change dark mode.

  Not seen on screen: Risk with real figures, Alerts with alerts, Backups
  with backups and the attribution sheet with data, all empty in a fresh
  copy and judged on their empty states; the Holdings editing table; the
  lower part of Settings → Connections. Increase Contrast, Reduce
  Transparency, Reduce Motion and Full Keyboard Access were not tried on
  screen, because that would change the settings of the owner's Mac; the
  first two are covered by tests that override the environment. The
  popover was not looked at, since its surfaces are deliberately unchanged.
- Review: written by an Opus worker from the session lead's specification.
  The session lead (Fable 5.2) read the launch options and their gate, the
  invariant check and the range switch in full, and looked at eight of the
  captures: the Overview in dark and light, Holdings and the charts page
  and Risk in dark, Allocation and Settings → Connections in light. It did
  not read every view's change. No independent second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - Whether VoiceOver reads the range switch as one group named by its
    label is not confirmed. Each segment was confirmed as a button that
    reports its selected state and can be pressed through accessibility.
    In-process hosting exposes no accessibility tree, so the test covers
    the function the control draws its accessibility from.
  - The charts page's line or candlestick switch lost the icons the native
    picker had.
  - Between this pull request and the shell's, the new cards sit in
    today's window and sidebar, so the app is part old and part new.
  - Data Health keeps separate tiles, and the grouped sections of native
    Settings forms keep the system look.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 138: Give the portfolio popover the Glass layout with today's movers

- What: the popover that opens from the portfolio's menu-bar item takes
  the layout the owner chose. From the top: "Portfolio" with the currency
  and the number of positions; the total, with its decimals smaller; the
  change, with its percentage in a badge; the graph, with a dotted
  "Yesterday's close" line on the Today range; the range switch, with the
  three ranges it had; "Today's movers"; total return beside net deposits;
  and the footer with the buttons it had. The owner's two conditions hold:
  the graph is under the total, and every holding is listed.

  The movers are always today's, whatever range is selected, because
  Folync gives a holding's change only for the day and in total. Each
  figure is the one the app already works out for a position's day;
  nothing here makes a request. They run from the biggest gain to the
  biggest loss, with unknown changes last and ties in order of name. A
  move that rounds to 0.00% is no change. The bars share one scale, the
  largest move rounded up to a whole percent and never less than 1%.
  Watch-list symbols, benchmarks and empty positions are not listed. A
  row shows the ticker alone, and the portfolio's name only where two
  holdings would otherwise read the same. VoiceOver reads a row as one
  sentence, such as "NVDA, up 2.69 percent today".

  The popover cannot grow past the screen. It is given the room under the
  menu bar, and the movers list takes what is left after the rest is laid
  out: at most twelve rows at once, fewer on a short screen but not under
  three, scrolling inside the popover.

  The headline follows the range switch, saying "past week" or "past
  month" after the amount. The second figure reads "Cost basis" when total
  return is measured against cost. The line about history coverage under
  the graph, the refresh button and the day-reference view for a Folync
  portfolio with no graph are kept. "Next up" and "Income this month" from
  the mock-up are not built; they need data that later pull requests
  bring.

  The popover's background is the system's own, as before. The popover's
  colours moved into the design file: gain and loss colours that are
  deeper in light mode, and secondary text that becomes primary under
  Increase Contrast. The per-symbol popovers took the new surfaces and
  nothing else; the notice that pull request 137 excepted from the surface
  check was theirs, it now uses the notice surface, and the exception is
  gone. Opening, closing and the dismissal monitors are unchanged, and so
  is the release on close of pull request 109.

  The acceptance copy gains one more launch option,
  `STOCKBAR_ACCEPTANCE_POPOVER=portfolio`. It opens the popover once, six
  seconds after launch, the way a click does and with the same dismissal.
  Without it the popover could not be looked at unless something clicked
  in the owner's menu bar. It has the gate of the other launch options.
- Merged: 2026-11-20, squash commit `564056b`. The merge published
  experimental build 382.3.7 as the prerelease `experimental-382.3.7`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark never
  opens the popover, so its launches do not run this layout; the status
  item's set-up gains one check of the launch options. Covered by the
  comparison after Phase A's last pull request.
- Testing, on macOS 27.2.1 and Xcode 27.2: 827 XCTest tests with 0
  failures. Thirteen are new, in `PortfolioCalculationTests.swift`: the
  movers' order with unknown changes and ties; the app's own figure used
  and only holdings listed; the ticker shown alone unless two rows would
  read the same; the bar scale and its floor; a bar never past its track;
  twelve rows before the list scrolls, and fewer on a short screen; the
  heading at every range; a down day; a row's text for VoiceOver; the
  figures in the portfolio's currency; the whole popover with 40 holdings
  kept inside a height limit, in a hosted view; and Increase Contrast
  reaching the popover's text. The launch option is added to the existing
  launch-option tests. `checks`, `docs-check` and `build-release` pass on
  the final commit. 103 Python helper tests and 95 script tests passed on
  the worker's last commit; the session lead's commit after it changed no
  Python and no script.

  The tests were shown to fail on broken code, each breakage applied, run
  and removed. By the worker: ties ordered backwards (one test failed);
  the twelve-row limit, the 1% floor and the watch-list filter removed
  together (four); the list ignoring the room it is given, and Increase
  Contrast ignored (three). By the session lead: the ticker shown alone
  even where two rows then read the same (one).

  On screen: the worker could not open the popover by the acceptance
  copy's process alone, and rendered its parts off screen instead, with 9
  and 40 holdings and on a down day, in dark and light. The session lead
  then added the launch option, opened the real popover in the acceptance
  copy and captured it, one window at a time, in dark and in light. The
  dark capture matches the mock-up. It also showed each row as "NVDA ·
  De…", the label a Folync aggregate gives a holding, which is what the
  ticker rule above fixes; the capture was taken again after the fix.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read the movers and the
  height limit, the change to how the popover is sized, and looked at the
  worker's renders and the two real captures. It did not read the whole
  view. It changed two things: the ticker rule and the launch option. No
  independent second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - The light popover is not confirmed on screen. A capture of the popover
    alone leaves out what is behind it, and in light mode the system's
    popover background then comes out dark grey under dark text. The
    prototype's capture of the system background showed the same on
    2026-11-19. The background is the one the popover had before this
    pull request, so on screen it should look as the light popover did
    before, but nobody has seen it.
  - A position whose previous close is missing shows 0.00%, not "–": the
    app's own figure for its day is zero in that case, and the list takes
    that figure as it is.
  - "Yesterday's close" is drawn only when the day's change is known and
    not zero, so a truly flat day has no line.
  - Pull request 109's release on close still has no test of its own.
  - Not looked at: the popover on a real short screen, Increase Contrast
    and Reduce Transparency on screen, and the glass the system gives the
    popover on macOS 26. Not listened to: VoiceOver.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 139: Give the Overview its total, longer ranges and what the total is made of

- What: the Overview takes the approved layout. At the head, the total
  as a large figure with its pence smaller, and beside it two lines,
  today's change and the change over the selected range, each with an
  amount and a badge. An unknown change shows "–" with the reason under
  it. Then the graph in a card, and under it a card that shows what the
  total is made of. The "Selected Position" panel stays, with everything
  it does, as a card of its own; the mock-up left it out, and removing a
  working feature is the owner's decision.

  The range switch offers six ranges where it offered three: 1D, 1W, 1M,
  3M, 1Y and All. For a Folync portfolio they use the history route and
  the saved copy the page already used; for the other sources, the stored
  portfolio values. No route, stored series or timer was added. There is
  no year-to-date range: Folync's history route has none, and asking for a
  custom span instead would save a new copy every day. The menu-bar
  popovers keep their three ranges. The range type no longer lists all
  its cases by itself, so code that offers ranges has to name them.

  The card is headed "What £84,310.47 is made of", with the total return
  after it, and has one bar in four parts with a legend: net deposits, the
  figure "Measure P&L Against" already uses; unrealised and realised
  gains, as Folync's snapshot gives them (realised gains were already
  decoded and unused); and "Income, interest and fees", which is the rest
  of the total. The rules, in `PortfolioTotalComposition`:
  - One currency. The card is built only when the total and the three
    figures are all known and all in the summary's currency. Nothing is
    converted. A figure Folync marks unavailable counts as unknown.
  - It adds up. Every figure is held in whole pennies, rounded as the
    app's money formatter rounds for display, and the remainder takes the
    rounding difference, so the four figures shown sum to the total shown.
  - A part that is zero or negative has no segment. Its figure is still
    shown, in red when negative, and a line under the bar says that the
    bar shows the positive parts only.
  - A figure Folync marks partial is labelled "Partial", and so is the
    remainder taken from it.
  - Only a Folync portfolio gets the card. The other sources give neither
    net deposits nor realised gains, and keep the old Summary card, as
    does a Folync portfolio whenever the card cannot be built.

  When Folync is not answering and saved figures are shown, an amber
  notice at the top says so and gives their time, and the total's label
  gains "as of" that time. It uses the connection state the app already
  has and makes no request. When the last failure was not a failure to
  connect, it says that Folync did not send new figures.
- Merged: 2026-11-20, squash commit `c9453fd`. The merge published
  experimental build 382.3.8 as the prerelease `experimental-382.3.8`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. This pull request
  changes code the benchmark runs: its launches open the main window on
  the Overview. Covered by the comparison after Phase A's last pull
  request.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull request 138 was
  merged this branch was brought up to date with it, and the figures here
  are for the two together: 841 XCTest tests with 0 failures. Fourteen are
  new, in `PortfolioCalculationTests.swift`: the parts adding up to the
  total after rounding, over 211 made-up cases, half pennies among them;
  the card hidden for a mixed or unknown currency and for sources without
  the figures; negative and zero parts; the ranges offered and the stored
  history serving the longer ones; the range line's text when history is
  stale or missing; the notice's states and words; the large figure's
  split in more than one locale; and the card's text for VoiceOver.
  `checks`, `docs-check` and `build-release` pass on the combined code.
  103 Python helper tests and 95 script tests passed on the worker's last
  commit; nothing they cover changed after it.

  Bringing it up to date took three small changes by the session lead,
  all where the popover meets the longer ranges: the popover's range
  switch lists the three menu ranges by name, its wording covers the
  longer ranges, and its test of the heading names every range itself.

  The tests were shown to fail on broken code, each breakage applied, run
  and removed: realised gains converted on their own (one test failed); a
  negative part given a width (one); the rounding difference dropped
  (one, in 211 cases); the notice shown while Folync answers (one); an
  unknown failure called unreachable (one).

  On screen: the worker ran the acceptance copy against the stand-in and
  captured the Overview, one window at a time, in dark and light, at the
  default and the minimum window size, at each of the six ranges. Six of
  those captures were taken before a last change to the axis labels and
  are named so. The stand-in always answers, so the notice and a negative
  part were rendered off screen from a temporary test and are shown by
  the committed preview. After bringing the branch up to date the session
  lead ran the combined build in the acceptance copy and captured its
  Overview and its popover in dark: six ranges on the Overview, three in
  the popover, both as intended.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read `PortfolioTotalComposition`
  in full and looked at five of the captures: the Overview in dark at one
  month, in light at the minimum size, the notice with a negative part,
  and the combined build's Overview and popover. It did not read the
  whole view. No independent second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - The range line counts money paid in or taken out as change. It is the
    last value less the first, as it was for one week and one month, and
    over a year that can be far from the return: in the acceptance copy
    one year shows +12.80% beside a total return of +23.25%. The user
    guide says so. Whether long ranges should show the gain without
    deposits is put to the owner.
  - No year-to-date range, as set out above.
  - Net deposits are kept for about fifteen minutes after Folync stops
    answering. In a longer outage the card gives way to the Summary card,
    where the mock-up of an outage shows the card.
  - Not seen on screen: a "–" change with its reason; the Overview of a
    local or Trading 212 portfolio; the Summary card as the fallback;
    Increase Contrast and Reduce Transparency on the new card.
  - On the stand-in, 1Y and All look the same, because its history starts
    about a year back.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 140: Give the main window the Glass shell with a floating sidebar

- What: the main window becomes the shell of the approved design. The
  owner chose the floating sidebar on 2026-11-20, knowing that macOS gives
  none in this window: a unified toolbar on the split view, a split-view
  controller's sidebar item and a background extension effect had each
  given the flat full-height one. So the app draws the panel and rebuilds
  what a standard sidebar gives for free.

  The window is see-through: it is no longer opaque, and the root view
  draws a blurred view of what is behind it under a light or dark wash.
  Under Reduce Transparency it is opaque. A unified toolbar with no
  customisation moves the traffic lights onto the panel and holds the
  sidebar button. The minimum size, 1060 by 680, is now held by
  constraints on the content view; the old way let the toolbar's height
  in, and the window could not be made shorter than about 700 points.

  The sidebar is a floating panel, inset 7 points with a 16-point corner.
  It uses real glass only behind `#available(macOS 26, *)`, and a system
  material with a hairline from macOS 15.4 to 25. Its width is fixed at
  213 points, which keeps every page as wide as it was. Its entries are
  in three groups: Portfolio (Overview, Holdings, Alerts), Analysis
  (Charts, Risk, Allocation) and System (Data Health, Backups,
  Diagnostics, Settings). Only sections that exist are listed. The page
  that was titled "Performance" is titled "Charts" everywhere a user sees
  it; its stored value does not change. A selected, a hovered and a
  pressed entry each look different. An entry can be dimmed with a
  reason, or carry a "New" badge; both are built and tested and nothing
  uses them yet.

  One list, `StockbarMainSection.sidebarGroups`, drives the sidebar, the
  View menu and the shortcuts, so they cannot drift apart. ⌘1 to ⌘9 now
  run in sidebar order: Overview, Holdings, Alerts, Charts, Risk,
  Allocation, Data Health, Backups, Diagnostics. That changes which
  number opens which page, and the user guide says so. View → Hide
  Sidebar and Show Sidebar, ⌃⌘S and the toolbar button collapse the
  panel, the page takes the width, and the choice is remembered. With
  focus in the sidebar, Up and Down move the selection and Home and End
  go to the first and last entry; Tab goes into the page and Shift-Tab
  comes back.

  The footer names the portfolio's source and says how fresh it is, with
  the refresh button. When Folync is not answering and saved figures are
  shown it turns amber and says "Couldn't reach Folync · figures from"
  and their time; a rejected token and a rate limit have their own words.
  It uses the status the app already has and makes no request.
- Merged: 2026-11-20, squash commit `92145d7`. The merge published
  experimental build 382.3.9 as the prerelease `experimental-382.3.9`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. Of the redesign's
  pull requests so far this is the one most likely to move a row: the
  main window the launches open is now see-through, with a blurred
  backing and a toolbar. It completes Phase A, so the phase's comparison,
  from `5fa923b` to the head, is due in the first quiet window.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull requests 138 and
  139 were merged this branch was brought up to date with them, and the
  figures here are for all of it together: 856 XCTest tests with 0
  failures. Fifteen are new, in `StockbarAcceptanceRuntimeTests.swift`:
  the groups and their order; each entry's shortcut, and the View menu
  and the sidebar coming from one list; the title "Charts"; hiding the
  sidebar and remembering it; the dimmed and badge states and the entry
  states; the footer's words for each state, the warning and its time
  among them; when the warning is announced; the keyboard's movement of
  the selection; and the words each entry gives VoiceOver. `checks`,
  `docs-check` and `build-release` pass on the combined code. 103 Python
  helper tests and 95 script tests passed on the worker's last commit;
  nothing they cover changed after it.

  The tests were shown to fail on broken code, each breakage applied, run
  and removed: Backups put before Data Health (the order, shortcut and
  keyboard tests failed); the sidebar choice not saved (two tests); the
  warning shown for a portfolio that is not Folync's (one); pressed drawn
  like hovered (one).

  On screen, in the acceptance copy against the stand-in, by the worker:
  captures, one window at a time, in dark and light, at the default and
  the minimum size, with the sidebar shown and hidden, and the amber
  footer with the stand-in stopped. Real clicks: all ten entries; the
  Overview's range switch at the default and the minimum size, sidebar
  shown and hidden; the toolbar's sidebar button; dragging the window by
  the page's strip and by the top of the panel. The keyboard: Up, Down,
  Home, End, Tab and Shift-Tab, ⌘-number for five pages, ⌃⌘S and ⌘R. Home
  and End did nothing at first, because AppKit turns them into scroll
  commands, and were fixed. The headings, each entry's title, position
  and selected state, and the footer's status were read from the copy's
  real accessibility tree. After bringing the branch up to date the
  session lead ran the combined build in the acceptance copy, captured
  the new Overview inside the new shell in dark and light, and made one
  real click on the Overview's range switch, which now sits in the
  window's top strip beside the toolbar: the range changed.

  Two of the worker's test clicks landed outside the acceptance window,
  near the top of the owner's screen: it had measured its coordinates
  against a screenshot of another size. No dialog appeared, the owner was
  told, and later clicks were taken from captures at the window's own
  size.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read the changes to the
  window controller and the menus, looked at three of the worker's
  captures, brought the branch up to date and looked at the combined
  build. It did not read the sidebar's view or its tests. No independent
  second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - A SwiftUI button drawn on the panel at the height of the traffic
    lights never received a real click, though it worked through
    accessibility. Why is not established. The sidebar button is a
    toolbar item for that reason, and anything placed that high needs a
    real-click check.
  - After opening Charts, the next click on another entry was lost twice
    in six tries; a second click always worked. Whether the app or the
    click tool is at fault is not known.
  - The sidebar cannot be dragged wider. Its width is fixed.
  - At the minimum width the Holdings table runs past the right edge of
    its card. Whether it did before is not known: the page is as wide as
    it was, but the old minimum could not be reached in the same way.
  - Not confirmed: that VoiceOver hears the sidebar as one list. SwiftUI
    gives it no list role, and the inspection tool shows no groups.
  - Not compiled with Xcode 26, which CI uses for `testing` and `main`.
    The glass call is guarded and nothing else is believed newer than
    macOS 14.
  - Never seen on screen: the dimmed and "New" entries, the hover and
    pressed states, Reduce Transparency, Increase Contrast, the fallback
    before macOS 26, zoom and full screen, and the see-through effect
    itself, which a capture of one window leaves out. Not heard:
    VoiceOver. Not tried: Full Keyboard Access.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 141: Add the Activity page: every Folync transaction, by month

- What: the first of the redesign's new pages. Activity lists every
  transaction of a Folync portfolio, read-only, from the transactions
  route that pull request 135 added. It is a new section in the Portfolio
  group after Holdings, with a "New" badge. For a portfolio that is not
  Folync's the entry is dimmed with "Needs a Folync portfolio", the page
  explains, and no request is made. ⌘1 to ⌘9 follow the sidebar, so the
  numbers shift again: Activity is ⌘3, and Diagnostics no longer has one.

  A capsule switch chooses the kind: All, Trades, Dividends or Cash. Each
  kind is a set of the route's actions, and every known action is in
  exactly one: buys, sells, splits and corporate actions under Trades;
  dividends and stock dividends under Dividends; deposits, withdrawals,
  interest, fees, tax, transfers and notes under Cash. All sends no
  filter, so an action this build does not know still appears. A second
  switch chooses "As entered" or "Adjusted", the route's two modes, and a
  search field filters by one holding's ticker.

  Rows are grouped by month, newest first, with no sums in the headings,
  because a month may be only partly loaded. A row has the day, the
  action, the ticker, a detail line with the quantity and price as Folync
  gives them, and the amount in the portfolio's currency. The amount is
  coloured by its direction and carries a written sign, which the owner
  asked for; a figure Folync does not give is "–", and a figure it marks
  partial or unavailable says so. The foot counts the rows shown and
  offers "Load more"; the route gives no total, so none is shown.

  The page keeps the rule that pull request 135 set for these routes. It
  asks when it becomes the selected page and on its refresh control, and
  at no other time. More rows come only from "Load more". A change of
  kind, mode or holding is held back for 400 ms and cancels the query it
  replaces. A result that arrives after its request was cancelled is never
  shown. It keeps no cache of its own: reuse inside five minutes is the
  fetch policy's.
- Merged: 2026-11-20, squash commit `474d187`. The merge published
  experimental build 382.3.10 as the prerelease `experimental-382.3.10`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark's
  launches set up no Folync and never open this page, so only the extra
  sidebar entry is in what they run. Covered by the comparison set for
  the night of 2026-11-20, if this is merged by then, or by the next one.
- Testing, on macOS 27.2.1 and Xcode 27.2: 881 XCTest tests with 0
  failures. Twenty-five are new, in `FolyncPortfolioSourceTests.swift`,
  with the coordinator stood in for: each state of the page; no request
  for a portfolio that is not Folync's; one request on opening and none on
  opening again; the refresh control forcing; load more, and a restart
  dropping the rows gathered; a change held back and a superseded change
  cancelled; a cancelled result never shown; going back to the query on
  screen asking nothing; the kinds, with every action in exactly one; the
  query for each combination of kind, mode and holding; months grouped by
  the transaction's own day; the direction, colour and sign of an amount
  for each action; the detail line; an unknown action; and each row's
  text for VoiceOver. One of them found a fault that was then fixed:
  going back to the previous choice while the new one was loading left
  the page on a spinner with nothing in flight. `checks`, `docs-check`
  and `build-release` pass on the final commit, and so do 103 Python
  helper tests and 95 script tests on the worker's last commit.

  The tests were shown to fail on broken code, each breakage applied, run
  and removed: the cancellation check removed (two tests failed); opening
  the page forcing a refresh (two); one action put in two kinds (two); a
  portfolio that is not Folync's asking (two); a restart adding to the
  rows (one); the hold-back removed (two); the spinner fix removed (one).

  Two tests of pull request 135's fetch policy are changed here. They
  waited on fixed delays, and during this work one of them failed once
  while other builds loaded the Mac: its two later callers had arrived in
  the other order. Both now wait until the policy has counted each caller
  before the next step, through a count the policy exposes for tests. The
  class was then run three more times.

  On screen: the worker ran the acceptance copy against the stand-in and
  captured the page, one window at a time, in dark and light, at the
  default and the minimum size; in Adjusted mode on a holding with a
  split; filtered to one holding; with no match; loading, with the
  stand-in answering slowly; with a 503 and nothing saved; with a 404;
  and with the capability left out. The stand-in's log matched the rule:
  one request on opening, one for "Load more", one for four letters
  typed, none for a leading space, none with the capability left out, and
  none on going back to "As entered" inside five minutes.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read the page's view model
  in full, looked at two of the captures, and changed the two tests
  above. It did not read the view or every test. No independent second
  review.
- Known issues:
  - The benchmark is owed, as set out above.
  - Not tried against a real Folync. The stand-in's answers follow the
    written contract and decode with the app's own models, and that is
    all.
  - A transfer is shown with no sign and a neutral colour, because the
    contract does not say which way its money goes.
  - A 503 with a saved copy was not seen on screen: each acceptance run
    starts with empty storage. Nor was the dimmed entry, since the
    acceptance copy always has a Folync portfolio. Both are tested.
  - Month headings have no sums, the search covers holdings only, and
    the foot gives no total, where the mock-up had all three.
  - A note has no money, and is shown with £0.00 as Folync gives it.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 142: Add the Trades page: every position opened, and how it did

- What: Trades shows Folync's trade analysis for a Folync portfolio,
  read-only, from the route that pull request 135 added. It is a new
  section in the Analysis group after Charts, with a "New" badge, dimmed
  with "Needs a Folync portfolio" for any other source. ⌘1 to ⌘9 follow
  the sidebar: with Activity and Trades added, Trades is ⌘6, Data Health
  is ⌘9, and Backups and Diagnostics have no number.

  Every figure on the page is Folync's own; the page works nothing out. A
  strip of four: the win rate, with a caption from the counts of wins and
  losses; how often a trade beat the S&P 500 over the same days; the
  total gain on trades; and this year's fees. Then a table with a row for
  each lot: the holding and its status, the day it was opened, the days
  held, its cost, its gain, its return, and its return against an index
  over the same days, in points. Then a card of one year's costs: fees as
  one figure, the value bought and sold with their counts, and turnover,
  with a switch for the year when Folync gives more than one.

  Three things are worded by what Folync's contract says, not by the
  mock-up. The last column is measured against each lot's own index,
  which is the FTSE 100 for a London holding, so it is headed "vs S&P"
  only when every row uses the S&P 500 and "vs index" otherwise; the note
  under the table names the indexes, and so do each cell's tooltip and
  its text for VoiceOver. The contract does not say which lots the win
  counts and the total gain cover, so their captions say "trades" and
  "open and closed trades, all time", not "closed trades". And Folync
  gives one figure for a year's fees, so commission and tax are not
  shown apart.

  The switch has four positions, All, Open, Partial and Closed, one for
  each status the route filters by. The worker built three; the route's
  "open" leaves out a position that is partly sold and still held, so
  the session lead added Partial.

  The page keeps the rule for these routes: it asks when it becomes the
  selected page, on its refresh control and on "Load more", and once more
  if the portfolio becomes a Folync portfolio while the page is open. A
  change of the switch is held back for 400 ms and cancels the query it
  replaces, and a result whose request was cancelled is never shown.
- Merged: 2026-11-20, squash commit `a60edd0`. The merge published
  experimental build 382.3.11 as the prerelease `experimental-382.3.11`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark's
  launches set up no Folync and never open this page. Covered by the
  comparison set for the night of 2026-11-20, if this is merged by then,
  or by the next one.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull request 141 was
  merged this branch was brought up to date with it, and the figures here
  are for the two together: 903 XCTest tests with 0 failures.
  Twenty-two are new, in `FolyncPortfolioSourceTests.swift`, with the
  coordinator stood in for: each state of the page; no request for a
  portfolio that is not Folync's; one request on opening and none on
  opening again; the refresh control forcing; load more, and a restart
  dropping the rows; a switch change held back and a superseded one
  cancelled; a cancelled answer never shown; the query for each position
  of the switch; the captions from the counts, a missing count included;
  the pill for each status and for one this build does not know; a lot
  with no benchmark figure showing "–" and not zero; the year chosen and
  the years offered; and each row's text for VoiceOver. `checks`,
  `docs-check` and `build-release` pass on the combined code. 103 Python
  helper tests and 95 script tests passed on the worker's last commit.

  The tests were shown to fail on broken code, each breakage applied, run
  and removed: a cancelled answer shown; the refresh control not forcing;
  a restart adding to the rows; a missing benchmark figure read as zero
  (two tests failed). Two more breakages were caught by nothing at first,
  a switch change that did not wait and a second opening that asked
  again; the worker strengthened the tests until each was caught.

  The worker's test of the hold-back waited on a real 400 ms and looked
  inside a 100 ms window. The session lead replaced the wait with a gate
  the test opens, so a busy Mac cannot change what the test sees.

  On screen: the worker ran the acceptance copy against the stand-in and
  captured the page, one window at a time, in dark and light, at the
  default and the minimum size, on All, Open and Closed; with a 503 and a
  saved copy; with a 503 and nothing saved; with a 404; with the
  capability left out; loading; and the explanation for a portfolio that
  is not Folync's. For the saved copy and the 404 it restarted its own
  stand-in on the same port during the run. The stand-in's log matched
  the rule: one request on opening, one for each change of the switch,
  only the last of two quick changes, and none on going back to All
  inside five minutes. After the merge with pull request 141 the session
  lead ran the acceptance copy of the combined code once, in dark, and
  captured its window: Activity and Trades are both in the sidebar with
  their badges, and the switch shows its four positions. It did not
  press the Partial position there.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read the switch, the
  hold-back and how a first page is asked for and applied, looked at the
  worker's capture of the page with data, and changed the two things
  above. It did not read the view or every test. No independent second
  review.
- Known issues:
  - The benchmark is owed, as set out above.
  - Not tried against a real Folync.
  - The captions of the win rate and the total gain rest on a reading of
    a contract that does not say which lots they cover.
  - Turnover is captioned "of average value", the base the fees figure
    names; the contract gives turnover no base.
  - The "Partial" pill and a "–" in the last column were not seen on
    screen, because the window could not be scrolled from the
    background. Both are tested.
  - The "New" badge is faint on the selected sidebar entry in dark mode.
  - "Showing 7 of 31" in the mock-up is "Showing N trades": the route
    gives no total.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 143: Add the Income page: dividends expected, received and by holding

- What: Income shows a Folync portfolio's dividends, read-only, from the
  route that pull request 135 added. It is a new section in the Analysis
  group after Charts, with a "New" badge, dimmed with "Needs a Folync
  portfolio" for any other source. ⌘1 to ⌘9 follow the sidebar: with the
  three new pages, Income is ⌘6, Trades ⌘7, Risk ⌘8 and Allocation ⌘9,
  and Data Health, Backups and Diagnostics have no number.

  At the top are Folync's own figures: the income expected in the next 12
  months, its declared and estimated parts, the yield on today's value
  and on cost, the income received in the last 12 months, and how many
  holdings pay. Each line is shown only when Folync gives the figure.
  Under them is a chart of twelve months, the six up to this one and the
  six after it, and three views: Outlook lists what is coming, soonest
  first, with ex-dividend dates; History lists payments received, newest
  first, with a payment's own currency when it differs; By holding sums
  each paying holding.

  Two sets of figures are Stockbar's own, and the page says so: the
  chart's bars and the By holding sums add up the payments Folync lists,
  by pay date read as a calendar day. An amount that is missing, marked
  unavailable or in another currency adds nothing and is counted in the
  note under the chart, and a sum with no known amount is "–", not zero.
  A payment is called Declared or Estimated only when Folync says which.

  The page keeps the rule for these routes: one request when it becomes
  the selected page, which serves all three views (every status, pay
  dates from twelve months back to twelve ahead, at the route's largest
  page); none on a change of view or on opening again inside five
  minutes; the refresh control and "Try now" force; "Load more" asks for
  the next page. No control changes the query, so nothing is held back.
  A result whose request was cancelled is never shown, and the page
  keeps no cache of its own.

  Against the mock-up: "Received so far in 2026" is "Received in the last
  12 months", the figure Folync gives; "all 9 holdings" is Folync's count
  of the holdings that pay; the earnings row is left for the Calendar;
  and an ex-dividend row has its amount in the amount column, so it fits
  at the minimum width.

  The session lead changed one thing in the worker's code. The contract
  lets Folync name no currency, and the page then labelled every figure
  as pounds. It now shows those figures without a symbol, leaves the
  currency out of the two captions, and does not add an amount that
  names a currency into a sum that has none.

  The User Guide said the Trades switch has three positions. It has had
  four since pull request 142, and the guide is corrected here.
- Merged: 2026-11-20, squash commit `9292744`. The merge published
  experimental build 382.3.12 as the prerelease `experimental-382.3.12`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark's
  launches set up no Folync and never open this page. Covered by the
  comparison set for the night of 2026-11-20, if this is merged by then,
  or by the next one.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull request 142 was
  merged this branch was brought up to date with it, and the figures here
  are for the three pages together: 931 XCTest tests with 0
  failures. Twenty-eight are new, in `PortfolioAnalyticsServicesTests.swift`,
  with the coordinator stood in for: each state of the page; no request
  for a portfolio that is not Folync's; one request on opening and none
  on opening again; the refresh control forcing; a refresh cancelling the
  load it replaces; a result for a page no longer selected never shown;
  load more, and a restart replacing the rows; the chart's months and the
  parts of a bar; a payment with no amount, and one in another currency,
  counted and not added; the order of what is coming; the pills; the By
  holding sums, a sum with no known amount included; each row's text for
  VoiceOver; and, added by the session lead, an answer that names no
  currency. `checks`, `docs-check` and `build-release` pass on the
  combined code. `python-tests` and 95 script tests passed on the
  worker's last commit; nothing they cover changed after it.

  The tests were shown to fail on broken code, each breakage applied,
  run and removed: a second opening that asked again; a cancelled or
  superseded result shown (two tests failed); an opening that forced a
  refresh (three tests failed); a payment with no detail counted as
  declared; amounts in another currency added up; and, by the session
  lead, the pound fallback put back.

  On screen: the worker ran the acceptance copy against the stand-in and
  captured the page, one window at a time: the three views in dark at
  the default size, Outlook and History in light and at the minimum
  size, loading, a 503 with nothing saved, the saved copy, a 404 and the
  capability left out. For the saved copy it stopped its own stand-in
  after the page had loaded. The stand-in's log matched the rule: one
  request on opening, none for four changes of view, one for the refresh
  control, none on leaving and coming back, and none with the capability
  left out. After the merge with pull request 142 the session lead ran
  the acceptance copy of the combined code once, in dark, and captured
  its window: Activity, Income and Trades are in the sidebar with their
  badges, and Outlook shows its figures, chart and rows.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read how the page chooses
  its currency and what depends on it, looked at the worker's capture of
  Outlook, and made the change above. It did not read the view, the view
  model in full or every test. No independent second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - Not tried against a real Folync.
  - "Load more" and the "incomplete" notice were not seen on screen: the
    stand-in's 109 payments fit in one page. Both are tested.
  - The dimmed entry and the explanation for a portfolio that is not
    Folync's were not seen on screen. Both are tested.
  - Rows below the fold in "What is coming" were checked through their
    VoiceOver text, not on screen: the window could not be scrolled from
    the background.
  - A Folync user sees "Income needs a Folync portfolio" until the first
    Folync snapshot exists, as on the other two pages.
  - A payment's own reason for being partial is not shown; only the
    reasons Folync gives for the whole answer are.
  - With no currency named, a payment whose amount does name one shows
    "–" in the portfolio column. Not seen with a real Folync.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 144: Allocation: a donut beside its list, three views and the correlations as a grid

- What: the Allocation screen shows the figures it already worked out in
  the layout of the approved mock-up. No figure's arithmetic changes; the
  two analysis services are untouched.

  A switch in the header chooses Sector, Holding or Currency. One card
  holds a donut with its list beside it, or under it when the window is
  narrow: each group's value and share, and for sectors today's change.
  The centre of the donut gives the total and the number of holdings.
  Past eight groups the smallest are folded into one "Other" slice and
  row that says how many it holds. The Currency view is new: holdings'
  values in the display currency, added up by the currency each is priced
  in, with pence counted as pounds. It is a plain sum of values the
  screen already had.

  The diversification score and the concentration are said once, in one
  card, with the existing recommendations as lines under them.

  The correlations are drawn as a grid, one row and one column for each
  holding, every cell showing its figure to two decimals and shaded by
  it: blue for a positive figure, orange for a negative one, nothing at
  zero. Each cell has a tooltip and a VoiceOver label ("VUSA and NVDA,
  0.73"). The grid holds the twelve largest holdings and says so when
  there are more; the three summary figures beside it still cover every
  holding. One line under it names the most and the least alike pair.
  The two lists of pairs that were there before are shown only past
  twelve holdings, when some of their pairs are not in the grid.

  Four sectors change colour, because their old colours read as gain or
  loss or sat too close to a neighbour's: Healthcare from red to
  lavender, Financials from green to teal, Real Estate from pink to sand
  and Basic Materials from mint to slate. No slice is red or green. A
  holding or a currency keeps the colour it is first given while the
  page is open.

  Kept as they were: the range control for the correlations, now beside
  the grid's heading; the notice when some holdings have no price or
  exchange rate; the attribution entry at the foot; every number format
  and every label of a figure. Changing the view recalculates nothing.

  Not built from the mock-up: a Funds group, which needs an instrument
  type that Folync does not give and Yahoo's has not been tried live; a
  Cash row, which would change every share the screen shows today; the
  words "Fair" and "Good" beside figures the screen gives no word to;
  and the line about a Returns page, which does not exist yet.
- Merged: 2026-11-20, squash commit `c34be9e`. The merge published
  experimental build 382.3.13 as the prerelease `experimental-382.3.13`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark's
  launches never open this page. Covered by the comparison set for the
  night of 2026-11-20, if this is merged by then, or by the next one.
- Testing, on macOS 27.2.1 and Xcode 27.2: 945 XCTest tests with 0
  failures. Fourteen are new, in `PortfolioAnalyticsServicesTests.swift`:
  the currency groups, pence with pounds and a holding with no value
  included; folding at nine groups and eight left alone; the order of
  each view; a group keeping its colour when another is added or removed;
  the grid's holdings past twelve and its line; a cell's text and label;
  the shade for a positive, a zero, a negative and an unknown figure; the
  line of pairs, with one pair only included; and the donut's centre.
  `checks`, `docs-check` and `build-release` pass. 103 Python helper
  tests and 95 script tests passed on the worker's last commit.

  The tests were shown to fail on broken code, each breakage applied, run
  and removed: folding at eight groups; pence kept apart from pounds; a
  leading zero kept in a cell; colours given by rank; and zero shaded.

  On screen: the worker ran the acceptance copy against the stand-in
  before and after the change and compared every figure, read from the
  window's accessibility text: both sectors' value, share and day change,
  the note about holdings with no known sector, and the two states' texts
  were the same. It captured the three views in dark, Sector in light,
  and both appearances at the minimum size.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read the grouping, folding
  and grid functions, and looked at three of the captures and at the
  worker's off-screen drawing of the grid. It did not read the view or
  every test. No independent second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - **The grid, the three figures beside it, the line of pairs and the
    diversification card with a score were never drawn in the running
    app.** The stand-in has too little shared price history and most of
    its portfolio has no known sector. The grid was seen only in a
    drawing made by a temporary test from a made-up matrix.
  - More than one currency was not seen on screen; the stand-in's
    portfolio is all in pounds. It is tested.
  - VoiceOver was not run; the labels were read as text.
  - "Least alike" names the lowest figure, which for a strongly negative
    one means the pair that moves most against each other.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 145: Switches in Settings for the Income, Trades and Activity pages

- What: Settings → Connections → Folync gains three checkboxes, "Income",
  "Trades" and "Activity", each with the "New" badge, after the four
  older ones. They turn the three pages' Folync routes off and on. The
  settings themselves have existed since pull request 135, on by default;
  until now nothing could turn them off.

  Beside each is its status, worded like the older rows' and taken from
  the capabilities answer the app already has: "Not supported by this
  Folync server" when the answer leaves the route out, "Unsupported",
  "Not ready" with Folync's reasons, or "Ready". No request is made to
  find a status out. A checkbox that is off cannot be turned on while its
  route is not usable; one that is on can always be turned off. The
  wording and that rule now live in one place, `FolyncRouteSettingsStatus`,
  which the older rows use too; what they say is unchanged.

  The block is headed "What Stockbar reads from Folync", with the line
  "Portfolio pages are fetched when you open them, not on a timer."

  **Turning one of the three off or on makes no request.** Saving a
  change to the older rows restarts the market-data schedule, which asks
  Folync for capabilities, benchmarks and rates. A change to the three
  new ones alone now saves and stops there, and clears nothing saved.
  The page concerned says it is switched off the next time it is opened,
  and asks again once it is switched on and opened.

  Against the mock-up: the rows are in one column, because the older
  rows' coverage lines and the longest status do not fit two at the
  minimum width; the label is "Income", not "Income and calendar", since
  there is no Calendar page yet; and there is no "Returns breakdown" row,
  since Folync has no such route yet.
- Merged: 2026-11-20, squash commit `80dfcbc`. The merge published
  experimental build 382.3.14 as the prerelease `experimental-382.3.14`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark's
  launches set up no Folync and never open Settings. Covered by the
  comparison set for the night of 2026-11-20, if this is merged by then,
  or by the next one.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull request 144 was
  merged this branch was brought up to date with it, and the figures here
  are for the two together: 953 XCTest tests with 0 failures. Eight
  are new, in `FolyncPortfolioSourceTests.swift`: the status for each
  route and each case, no capabilities answer included; one route left
  out changing only its own row; the older rows keeping their wording;
  the rule for turning on and off; saved settings decoding unchanged;
  each switch saving only its own setting, leaving the others, the
  address and the portfolio as they were, and making no request, while
  an older row's switch still does; and which changes count as needing no
  request. `checks`, `docs-check` and `build-release` pass on the
  combined code. 103 Python helper tests and 95 script tests passed on
  the worker's last commit.

  The tests were shown to fail on broken code, each breakage applied,
  run and removed: the schedule restarted for one of the new switches;
  a route that is not ready allowed to be turned on; dividends read as
  trade analysis; the reasons dropped from "Not ready"; "New" dropped
  from the name VoiceOver reads; and a change to the fallback treated as
  one of the new switches.

  On screen: the worker ran the acceptance copy against the stand-in and
  captured the Connections tab before and after, in dark and light, at
  the default and the minimum size, and with one route left out and one
  not ready, which showed the right statuses. The stand-in's log showed
  no request for any change of a switch.

  **A switched-off page was not seen on screen, and the reason is a fault
  in the acceptance copy, not in the app.** The worker found that a
  switch it turned off was on again when Settings was next opened, and
  that the older "Exchange rates" switch does the same on `experimental`
  without this change. The session lead traced it: the acceptance copy
  keeps its defaults in a suite named by a path, and on macOS 27.2.1 a
  process never reads back its own change to a key that was already in
  such a file when it started. The harness seeds the Folync settings
  before it starts the app, so those are the keys the copy cannot change.
  Two small programs outside the repository showed the same with no
  Stockbar code in them, and showed that a suite named in the ordinary
  way reads back correctly. The released app uses the standard defaults,
  not a suite named by a path.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read the status type and
  the change to how a settings change is saved, looked at one capture,
  and traced the fault above with a temporary log line that was never
  committed. It did not read the view or every test. No independent
  second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - No page's "switched off" state, and no page asking again after being
    switched back on, was seen in a running copy, for the reason above.
    Both are tested with the store stood in for.
  - The acceptance copy cannot change any setting seeded before it
    starts: the Folync address, portfolio and seven route settings. So a
    portfolio that is not Folync's cannot be seen there either. Fixing it
    means having the app seed its own settings in an acceptance run; not
    done here.
  - Not tried against a real Folync.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 146: Holdings: a Weight column and one switch for amounts or percentages

- What: the Holdings screen gains a Weight column, between Value and
  Today: the holding's share of the portfolio to one decimal. It sorts,
  with an unknown weight below every known one.

  For a Folync portfolio the weight is Folync's own figure for the
  holding, shown as given and never worked out here; "–" where Folync
  gives none. Folync's contract does not say what that figure is a share
  of, so the line under the table says "Weight is Folync's figure" and
  no more. For a local or Trading 212 portfolio it is the holding's
  value as a share of the net value the strip shows, both in the same
  currency, and "–" when the value, the currency, the exchange rate or a
  positive total is missing. A watchlist row has no weight.

  One visible switch, Amounts and Percent, beside the search field, sets
  both the Today and the Total gain columns, and is remembered. Before,
  each column switched when one of its cells was clicked, which nothing
  on the screen said; clicking a cell now does nothing. The heading
  "Total P&L" is "Total gain".

  The strip keeps its three figures and where they come from. The US
  dollar equivalent moves from brackets to a second line, and the total
  gains say what they are for the source: "Unrealised, as Folync reports
  it", "Unrealised, as Trading 212 reports it", or "Unrealised, against
  average cost" for Stockbar's own sum.

  Under the read-only table one line counts what is shown, "9 holdings
  and 2 watchlist symbols.", with the right singular and plural forms.

  **The fault at the minimum window size is fixed for the read-only
  table:** every column, Weight included, is inside the card; before, the
  last heading was cut off. Numbers are right-aligned. VoiceOver reads a
  row as one sentence, with the weight and whichever of amount or
  percentage is showing.

  The editing table for a local portfolio is unchanged. The worker had
  narrowed every one of its columns so that it fitted the card at the
  minimum size; that layout cannot be seen in the acceptance copy, which
  is always a Folync portfolio, so the session lead put the widths back.
  It is wider than the card at the minimum size and scrolls sideways
  there, as it always has. Weight is not shown in it.
- Merged: 2026-11-20, squash commit `9d87d22`. The merge published
  experimental build 382.3.15 as the prerelease `experimental-382.3.15`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark
  opens the main window on the Overview and never opens this page.
  Covered by the comparison set for the night of 2026-11-20, if this is
  merged by then, or by the next one.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull request 145 was
  merged this branch was brought up to date with it, and the figures here
  are for all of it together: 964 XCTest tests with 0 failures.
  Eleven are in a new class in `PortfolioCalculationTests.swift`: a
  Folync holding's weight as given and "–" when Folync gives none; a
  local holding's weight, with a value, a currency or a total missing; a
  watchlist row; the weight's text and its sort order; the one switch and
  its stored key; the strip's second lines for each source; the line
  under the table for one, two and no watchlist symbols; a row's sentence
  for VoiceOver in both modes; and that the editing table's widths are
  what they were. `checks`, `docs-check` and `build-release` pass on the
  combined code. 103 Python helper tests and 95 script tests passed on
  the worker's last commit.

  The tests were shown to fail on broken code, each breakage applied,
  run and removed: unknown weights sorted first; "holdings" used for one
  holding; the Folync gains called "against average cost"; and a Folync
  weight worked out from values. A fifth, a wider column in the editing
  table, was caught by a test of the narrowed layout that went with it.

  On screen: the worker ran the acceptance copy against the stand-in and
  captured the page before and after, in dark and light, at the minimum
  size and at 1286 by 850, in Amounts and in Percent, sorted by Weight
  and with a search. Its first version left the cells showing the old
  choice when the switch changed; it saw that on screen and fixed it.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read the layout change and
  what else changed in the editing rows, looked at the worker's captures
  at the minimum size, and put the editing table's widths back. It did
  not read the rest of the view or every test. No independent second
  review.
- Known issues:
  - The benchmark is owed, as set out above.
  - **The editing table was not seen on screen**, before or after: the
    acceptance copy cannot be a local portfolio (see record 145).
  - Watchlist rows were not seen on screen; the stand-in has none.
  - The weight and the gains caption for a Trading 212 portfolio are not
    tested: no test helper builds a broker snapshot.
  - The choice of Amounts or Percent surviving a relaunch was not seen;
    each acceptance run starts with fresh storage.
  - With a fresh Trading 212 snapshot the net value is the broker's whole
    account, cash included, so a holding entered by hand beside it is
    weighed against a total that leaves it out.
  - An unknown figure in a row is now "–" in every column; Value, Today
    and Total gain used "—".
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 147: Risk: each figure said once, with a chart of the falls

- What: the Risk screen shows the figures it already worked out, each
  once, in the order of the approved mock-up. No existing figure's
  arithmetic changes: the same functions of `RiskMetricsService` give the
  same numbers, to the same number of decimals.

  The header has the title, the line "How bumpy the ride has been", the
  recalculate control and all five ranges. Under it is a strip of four:
  volatility, the Sharpe ratio, the Sortino ratio and the worst fall, as
  a negative percentage with its length. The words under volatility and
  the Sharpe ratio are the screen's own, with their thresholds unchanged.

  "How far below its peak" is new: a chart of how far the portfolio stood
  below its highest value so far, day by day, with the lowest point
  marked and labelled. Its series is the one piece of new arithmetic, a
  pure function beside the existing ones, over the same values and dates
  as the maximum drawdown, so its lowest point is the strip's worst fall
  exactly; a test holds the two together on five series. The chart has a
  sentence for VoiceOver and its draw-in is off under Reduce Motion.

  "On a bad day" gives the two value-at-risk figures in plain words, once
  each. "Falls of more than 5%" lists the falls the screen listed before,
  with their dates and lengths. A footnote replaces "Calculation Details":
  how many trading days the figures rest on, from when to when, that the
  history is Stockbar's own and not Folync's (said for a Folync portfolio
  only), the method, and the risk-free rate. Downside deviation, which
  the mock-up leaves out, is kept as a small figure above the footnote.

  Gone: the six cards and the three sections that repeated them, with
  their colour bands for the two ratios and their explanatory captions;
  the calculation date and the "Time Range" row, which the footnote and
  the range switch already say.

  **One label is corrected.** The length of the worst fall was called
  "trading days" on the old screen and in the worker's version. The
  service counts calendar days from the peak to the low whenever it has
  the dates, and the screen always gives it the dates, so the strip now
  says "90 days, peak to low", as the list of falls does. The number is
  the same.

  Against the mock-up: percentages keep two decimals and ratios three,
  because the figures must stay what they were; and the screen keeps the
  recalculate control, the currency notice, the limit of five falls and
  the note that recovery time is not counted.
- Merged: 2026-11-20, squash commit `995293c`. The merge published
  experimental build 382.3.16 as the prerelease `experimental-382.3.16`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark
  opens the main window on the Overview and never opens this page.
  Covered by the comparison set for the night of 2026-11-20, if this is
  merged by then, or by the next one.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull request 146 was
  merged this branch was brought up to date with it, and the figures here
  are for all of it together: 978 XCTest tests with 0 failures.
  Fourteen are new, in `RiskMetricsServiceTests.swift`: the series for a
  history that only rises, one that falls and recovers, one still falling
  at the end, one day and none; its lowest point against the maximum
  drawdown; the label of the lowest point and the chart's sentence; the
  words under each tile, a figure that is not known included; the two
  bad-day sentences; a row of the falls and the empty line; and the
  footnote for a Folync and a local portfolio. `checks`, `docs-check` and
  `build-release` pass on the combined code. 103 Python helper tests and
  95 script tests passed on the worker's last commit.

  **The figures were held to the old screen's.** Before changing
  anything the worker ran the old screen's own formatting on four made-up
  histories and kept what it printed; a test builds the same figures
  through the new code and compares every one. The only differences are
  the minus sign on a fall, "–" for an unknown figure where the old
  screen had "—", and the corrected label above.

  The tests were shown to fail on broken code, each breakage applied,
  run and removed: a peak that never moved; the minus sign dropped; a
  Sharpe threshold changed; "not Folync's" always shown; the last of two
  equal lows taken; percentages to one decimal; and the two bad-day
  amounts swapped.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read how the length of a
  fall is counted and worded, looked at the worker's drawing of the
  filled page, and corrected the label above. It did not read the view
  or every test. No independent second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - **The filled page was never seen in the running app.** The
    acceptance copy has no stored history, so Risk shows "Not enough
    history" there, before and after. The filled page was seen only in
    drawings made off screen from made-up histories, in dark and light,
    at the default and the minimum width.
  - VoiceOver, Reduce Motion and Increase Contrast were not tried on a
    running app.
  - The Sortino ratio no longer has a colour; the colour was the only
    judgement the old screen gave it.
  - The horizontal axis shows the months Swift Charts picks, which need
    not include the first.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 148: Let the acceptance copy change the settings it was started with

- What: no change to what users see. The acceptance copy could not
  change any setting that was seeded before it started (record 145): a
  Folync switch turned off there was on again, and "Use Local
  Portfolio…" could not take effect. The cause is its defaults suite,
  which is named by a path: on macOS 27.2.1 a process never reads back
  its own change to a key that was already in such a file when the
  process started, while a key it creates itself reads back correctly.

  So the app process now writes the seeded settings itself.
  `--acceptance-bootstrap` no longer opens the defaults suite. It writes
  the same Folync settings as JSON to one seed file in the run's own
  root, readable by the owner only and renamed into place, and still
  saves the token to the acceptance Keychain service. At launch, after
  the preflight and bootstrap arguments are handled and before the
  application object exists, an explicit acceptance run that has a seed
  decodes it, saves it through `FolyncSettingsStore` and deletes the
  file. A missing seed does nothing. One that cannot be read stops the
  launch with a message and exit status 2, and changes nothing.

  **No rule is loosened, and one is applied twice.** Only an explicit
  acceptance run looks for a seed: a normal launch and the tests'
  automatic isolation return before looking for a file or creating the
  defaults. The seed is refused unless it names plain HTTP to this Mac
  with no credentials in the address, the same rule the bootstrap
  applies to its manifest, now in one function used by both. A seed that
  is not a regular file is refused. The harness scripts are unchanged.
- Merged: 2026-11-20, squash commit `3aff316`. The merge published
  experimental build 382.3.17 as the prerelease `experimental-382.3.17`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. What a normal
  launch gains is one check of the acceptance environment before the
  application object is made; the benchmark's launches do run that.
  Covered by the comparison set for the night of 2026-11-20, if this is
  merged by then, or by the next one.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull request 147 was
  merged this branch was brought up to date with it, and the figures here
  are for all of it together: 992 XCTest tests with 0 failures.
  Thirteen are in a new class in `StockbarAcceptancePreflightTests.swift`:
  the bootstrap writes an owner-only seed inside the root and nothing
  into the suite; adopting moves every field and removes the seed;
  adopting twice is harmless, and a change made in between survives; a
  missing seed does nothing; an unreadable seed, and one that is not a
  regular file, fail and change nothing; a seed naming a Folync off this
  Mac is refused; the loopback rule itself; and nothing is adopted in a
  normal launch, under the tests' automatic isolation, or in a run
  without the loopback exception. One more, beside the existing ones,
  checks that a manifest naming a Folync off this Mac writes no seed.
  The existing tests' set-up gave every test the same root, through a
  missing backslash; that is fixed. `checks`, `docs-check` and
  `build-release` pass on the combined code. 103 Python helper tests and
  95 script tests passed on the worker's commit.

  The tests were shown to fail on broken code, each breakage applied,
  run and removed: the gate widened to any acceptance run; the seed not
  deleted; the bootstrap also writing the suite; the seed readable by
  others; and no loopback check on adoption.

  **On screen, the proof a unit test cannot give.** In a copy built from
  `experimental` before this change the worker turned "Trades" off; the
  page still loaded and the stand-in logged the request; back in
  Settings the checkbox was on. In a copy built from this branch the
  page said "Trade analysis is switched off" and no request was logged;
  the checkbox was still off; turned on again, the page loaded.
  "Exchange rates" stayed off after leaving Settings and coming back.
  "Use Local Portfolio…", confirmed in the copy's own sheet, gave a
  local portfolio: Activity, Income and Trades dimmed in the sidebar
  with "Needs a Folync portfolio", and each page showing its
  explanation. These states of pull requests 141 to 145 had not been
  seen on screen before.

  It also showed the Holdings editing table for the first time. At the
  default size it fits its card. **At the minimum size its last column,
  the row actions, is past the card's right edge.** The table is in a
  sideways scroll view; whether it scrolled could not be confirmed from
  the background. This is how it was before pull request 146 and is
  what the worker of that pull request had tried to fix.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) read every changed line of
  the three source files, checked the gate and that a run always has a
  root, looked at two captures, and added a sentence to the
  architecture notes. It did not read every test. No independent second
  review.
- Known issues:
  - The benchmark is owed, as set out above.
  - The launch that stops on an unreadable seed is tested as a function,
    not as a launch.
  - A second launch on the same root would meet the old fault, since the
    keys are then in the file. The harness makes a new root for every
    run.
  - No light-mode captures of the new states; the confirmation sheet was
    seen and not captured.
  - The Holdings editing table at the minimum size, above. A fix that
    can now be looked at is the next piece.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 149: Charts: the controls in one row and the chart on a card; a full Data Health grid

- What: a tidy of two screens that had no mock-up. Nothing is added and
  nothing is taken away.

  On Charts the controls sat in three rows that lined up with nothing:
  "Chart" and its picker a third of the way across, "Time Range" further
  right, "Comparison Mode" at the left. Now the chart picker is at the
  left, flush with the page, and the range switch at the right, on one
  row, where the other pages have theirs; the visible labels are gone and
  both controls keep their accessibility labels. The custom dates appear
  under the range switch, right-aligned. One strip holds everything that
  changes how the chart is drawn: the Line and Candlestick switch, "Chart
  options", "Comparison Mode" and the source and coverage note. The
  strip, the comparison picks, the chart with its loading and empty
  states, and the caption under it are on one card. Everything under the
  card keeps its order and its code. The page no longer has side padding
  of its own, so it lines up with its header.

  One fault of the old layout showed up and is fixed: a short card was
  centred in the page's minimum height, which moved the controls down
  whenever a chart was loading or empty.

  On Data Health the six tiles made four columns at the default window
  size, leaving two alone on a second row. The grid is now three columns
  when three tiles of the same minimum width fit, otherwise two, so six
  tiles always make full rows.

  No saved setting changes its key, and nothing about how or when a
  chart's data is loaded is touched.
- Merged: 2026-11-20, squash commit `241aeb7`. The merge published
  experimental build 382.3.18 as the prerelease `experimental-382.3.18`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark
  opens the main window on the Overview and opens neither page. Covered
  by the comparison set for the night of 2026-11-20, if this is merged
  by then, or by the next one.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull request 148 was
  merged this branch was brought up to date with it, and the figures here
  are for all of it together: 995 XCTest tests with 0 failures.
  Three are new, in `PortfolioCalculationTests.swift`, for the Data
  Health grid's column count: three once three tiles fit, two below
  that, and six tiles always in full rows. Two breakages of that rule
  were each caught and removed. The Charts change moves views and has no
  logic of its own to test. `checks`, `docs-check` and `build-release`
  pass on the combined code. 103 Python helper tests and 95 script tests
  passed on the worker's last commit.

  **On screen, which is what checks this piece.** The worker ran the
  acceptance copy before and after and used the controls after the
  change: three chart types; the range switch, with the point count
  changing; the custom dates, stepped and reloading; comparison on, a
  second stock added, normalised off, cleared, off; Line and Candlestick,
  with the candlestick's hover read-out; grid lines, gradient fill and
  line width from "Chart options"; the line chart's hover read-out; the
  metrics collapsing; the filters' select all, clear, zoom in and reset.
  The captures are before-and-after pairs in dark and light, at the
  default and the minimum size, where the picker and the range switch
  still share a row.

  The worker could not settle one thing: "All Time" showed "Unavailable"
  in its last run, made with the stand-in slowed and the disk full.
  After the merge with pull request 148 the session lead ran the
  acceptance copy of the combined code: "All Time" drew the portfolio
  chart from 230 points and a single stock from 519, and Data Health
  showed two full rows of three.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) looked at the before and
  after captures of a single stock, of comparison with custom dates at
  the minimum size, and of Data Health, and did not read the moved
  views. No independent second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - "Export CSV" and "Export PDF" were not pressed: they open a system
    save panel. The value threshold filter, the filter's own date range,
    zoom out, and the candlestick's indicator and option menus were not
    used. The progress and error views did not appear.
  - The fallback that puts the range switch on a row of its own was
    never seen: the two fit on one row at the minimum size.
  - Not tried against a real Folync or live prices.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 150: Holdings: the editing table fits at the minimum window size

- What: for a local portfolio in Edit mode the Holdings table's columns
  have fixed widths that add up to 969 points, and the card is 784
  points wide at the window's minimum size. The last column, the row's
  watchlist, move and remove buttons, was out of sight there; the table
  scrolls sideways, but nothing showed that. Pull request 148 made it
  possible to see this in the acceptance copy.

  The table now has two sets of widths and chooses by the room it has.
  The regular set is the old one, unchanged, and is used whenever the
  table is at least 969 points wide, which is a window at least 1245
  wide. Below that a compact set is used: 66, 100, 86, 90, 84, 84, 96
  and 88 points, with 8 between columns, 12 at the sides and 6 between
  the action buttons, 774 in all, so every column is inside the card at
  the minimum size. The table measures its width where it already did
  and hands one set to the header and to every row, so the two cannot
  disagree. The sideways scroll view stays as the fallback.

  Nothing else in the editing rows changes: the fields, the buttons,
  their tooltips and VoiceOver labels, the order of the columns and how
  a change is saved. Weight is still not shown in the editing table.
- Merged: 2026-11-20, squash commit `2d5d992`. The merge published
  experimental build 382.3.19 as the prerelease `experimental-382.3.19`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark
  opens the main window on the Overview, with no local holdings being
  edited. Covered by the comparison set for the night of 2026-11-20, if
  this is merged by then, or by the next one.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull request 149 was
  merged this branch was brought up to date with it, and the figures here
  are for all of it together: 999 XCTest tests with 0 failures.
  Five replace the one that pinned the old widths: the regular set's
  figures and their sum; the compact set's; that the compact set fits
  the card at the minimum window size, worked out from the same values
  the window and the shell use; which set is chosen at, just above, just
  below and far below the threshold; and that a set's width is its
  columns, spacing and padding. `checks`, `docs-check` and
  `build-release` pass on the combined code, and the Python helper tests
  and the script tests pass.

  The tests were shown to fail on broken code, each breakage applied,
  run and removed: a compact column made wider; the threshold's "at
  least" made "more than"; the threshold ignored, so that the regular
  set was always used (two tests failed); and one space too many counted
  in a set's width (three tests failed).

  **The worker was cut off before its checks.** The Mac's disk filled
  while it was showing the tests to fail, and no command could start. It
  stopped with two breakages done, one of them still in its working
  tree, and no full test run. The session lead cleared the space,
  removed the leftover breakage, ran the remaining breakages and every
  check, and that is what the figures above are.

  On screen, in a copy made a local portfolio: at the minimum size, in
  dark and light, every column is inside the card with entries of
  realistic length ("VUSA.L", 1234.5678 units, costs of 87.4321 and
  12345.67, the currency pickers) and nothing is cut short. The worker
  pressed watchlist, move up and move down with pointer clicks and each
  worked; remove showed its confirmation, which was cancelled. At 1250
  points wide the regular set is used and the columns stand where they
  did before; at 1240 the compact set is used. The read-only table is
  the same before and after. Typing in the compact fields behaved
  normally.
- Review: written by an Opus worker from the session lead's
  specification. The session lead (Fable 5.2) looked at the capture at
  the minimum size, finished the worker's checks as set out above, and
  did not read the changed views. No independent second review.
- Known issues:
  - The benchmark is owed, as set out above.
  - The Current and Value columns showed "-" throughout, because the
    acceptance copy fetches no prices. Their compact widths are sized by
    estimate: a price of £10,000 or more is close to the edge of 84
    points. A figure too long for its column wraps and makes the row
    taller; it is not cut off.
  - That the header and the rows use the same widths rests on one value
    being passed to both; no test covers it, because those views are
    private.
  - One of the units entries was put in through accessibility, not as
    keystrokes.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 151: Record the redesign benchmark and bring the log up to date

- What: the comparison of `5fa923b` against `2d5d992`, which covers pull
  requests 135 to 150, with both of its runs and their tables, in this
  entry; the merge line of pull request 150;
  [Where things stand](#where-things-stand) brought up to date from pull
  request 141; and rows in "Who did what" for pull requests 144 to 150,
  the disk that filled during pull request 150 included, and for this
  one. Only this file changes.
- Merged: 2026-11-21, squash commit `381fad1`. The merge published
  experimental build 382.3.20 as the prerelease `experimental-382.3.20`.
  Checked after it: the prerelease is listed. The published archive was
  not downloaded or opened.
- Benchmark: no before/after run for this pull request. No file that goes
  into the app changes (nothing under `Stockbar/`, `StockbarTests/` or
  `Stockbar.xcodeproj`), so before, `2d5d992`, and after build the same
  app. What it records is the comparison owed by pull requests 135 to 150
  under the rule of 2026-11-20 (see
  [How this branch works](#how-this-branch-works)).

  Before `5fa923b`, the last commit measured, after `2d5d992`, the
  standard comparison, six launches a side in turns, run twice on
  2026-11-20, on macOS 27.2.1 and an Apple M3 Pro with 18 GB, on mains
  power, with the lid open, the screen unlocked and no other project's
  build present. It had been set for 02:30 UTC on 2026-11-21; the owner
  asked for it that evening instead. Each run started only after twenty
  quiet minutes on mains power, checked every twenty seconds, and under
  the three rules of pull request 134's comparison, written into its
  script before it began: a run is set aside and repeated if more than
  two readings inside the turns show input in the minute before, if the
  four busiest processes together are more than 1.5 times busier over
  one side's turns than the other's, or if any measured launch has
  another project's build beside it.

  A first attempt began its wait at 21:27 UTC, started at 21:46, built
  both commits and was cut off by a restart of T3 Code during round 1's
  warm-up launch, at 21:49. It measured nothing. Its folder is kept, with
  an empty `before-1`, as
  `build/bench/results/interrupted-compare-redesign-20261120-214659`.

  First run: wait from 21:50 UTC, turns from 22:10 to 22:43 UTC. The Mac
  had been untouched for 9466 s when it started, and no reading inside
  the turns showed input. The four busiest processes together averaged
  108% of a core over the before side's 16 readings and 100% over the
  after side's 16, a ratio of 1.08, so the run stands. None of the
  measured segments, six launches and two helper measurements a side,
  had another project's `xcodebuild` beside it. The highest load average
  at the ten-second samples was 8.9, once, during the after side's second
  launch; everywhere else it stayed at or below 4.4. Four rows are
  higher, and two are marked possibly higher. (This sentence said "three"
  until pull request 153 corrected it.)

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 96.9 (96.3 to 99.3) MB | 119.1 (118.0 to 120.4) MB | +22.2 MB, +22.9% | higher (p = 0.002) |
  | Idle memory the app holds allocated | 50.8 (50.7 to 51.2) MB | 52.2 (51.3 to 53.2) MB | +1.3 MB, +2.6% | higher (p = 0.002) |
  | Peak memory, launch and history load | 244.2 (242.7 to 248.3) MB | 267.5 (262.7 to 271.9) MB | +23.3 MB, +9.5% | higher (p = 0.002) |
  | Idle memory growth across the window | 0.1 (0.0 to 0.4) MB | 0.2 (0.1 to 0.5) MB | +0.2 MB, +400.0% | no measurable change (p = 0.054) |
  | Idle CPU | 0.087 (0.073 to 0.090) s/min | 0.098 (0.075 to 0.108) s/min | +0.011 s/min, +12.1% | possibly higher (p = 0.037) |
  | Idle CPU wake-ups | 26 (24 to 27) /min | 26 (25 to 28) /min | +0 /min, +0.0% | no measurable change (p = 0.634) |
  | Idle CPU power | 3.60 (3.51 to 3.93) mW | 3.94 (3.61 to 4.73) mW | +0.34 mW, +9.4% | possibly higher (p = 0.037) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.48 (0.45 to 0.52) s | 0.49 (0.45 to 0.51) s | +0.01 s, +1.0% | no measurable change (p = 1.000) |
  | Launch to history loaded | 0.59 (0.57 to 0.60) s | 0.59 (0.56 to 0.61) s | +0.00 s, +0.0% | no measurable change (p = 0.998) |
  | CPU from launch to the idle window | 1.67 (1.63 to 1.70) s | 1.78 (1.76 to 1.82) s | +0.11 s, +6.9% | higher (p = 0.002) |
  | CPU energy from launch to the idle window | 5.28 (5.18 to 5.34) J | 5.46 (5.20 to 5.69) J | +0.18 J, +3.4% | no measurable change (p = 0.132) |
  | Python helper start to ready, no network | 0.27 (0.26 to 1.20) s | 0.27 (0.25 to 0.53) s | -0.01 s, -1.9% | no measurable change (p = 0.621) |
  | Python helper start, CPU | 0.27 (0.25 to 0.38) s | 0.26 (0.25 to 0.33) s | -0.01 s, -1.9% | no measurable change (p = 0.671) |
  | Python helper memory once started | 71.1 (71.0 to 71.2) MB | 71.1 (71.1 to 71.2) MB | +0.0 MB, +0.0% | no measurable change (p = 0.394) |

  Repeat, for those rows: wait from 22:43 UTC, turns from 23:03 to 23:35
  UTC. No reading inside the turns showed input. The four busiest
  together averaged 91% of a core over the before side's 16 readings and
  105% over the after side's 16, a ratio of 1.16, so it stands. Again no
  measured segment had another project's build beside it, and the load
  stayed at or below 5.5.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 97.3 (95.5 to 99.3) MB | 118.3 (116.6 to 119.6) MB | +21.0 MB, +21.6% | higher (p = 0.002) |
  | Idle memory the app holds allocated | 51.0 (50.7 to 52.1) MB | 51.1 (50.5 to 52.6) MB | +0.1 MB, +0.3% | no measurable change (p = 0.509) |
  | Peak memory, launch and history load | 245.9 (241.8 to 248.4) MB | 266.1 (260.9 to 275.5) MB | +20.2 MB, +8.2% | higher (p = 0.002) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.4) MB | 0.2 (0.2 to 0.5) MB | +0.2 MB | possibly higher (p = 0.013) |
  | Idle CPU | 0.084 (0.070 to 0.101) s/min | 0.102 (0.074 to 0.105) s/min | +0.018 s/min, +20.8% | no measurable change (p = 0.078) |
  | Idle CPU wake-ups | 26 (24 to 27) /min | 26 (24 to 28) /min | +0 /min, +0.0% | no measurable change (p = 0.470) |
  | Idle CPU power | 3.58 (3.40 to 4.14) mW | 3.79 (3.63 to 4.27) mW | +0.21 mW, +5.9% | no measurable change (p = 0.143) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.47 (0.46 to 0.49) s | 0.48 (0.45 to 0.54) s | +0.01 s, +1.1% | no measurable change (p = 0.983) |
  | Launch to history loaded | 0.58 (0.57 to 0.59) s | 0.60 (0.59 to 0.67) s | +0.03 s, +4.3% | higher (p = 0.006) |
  | CPU from launch to the idle window | 1.68 (1.62 to 1.71) s | 1.77 (1.75 to 1.94) s | +0.09 s, +5.7% | higher (p = 0.002) |
  | CPU energy from launch to the idle window | 5.27 (5.17 to 5.40) J | 5.35 (5.22 to 5.45) J | +0.08 J, +1.4% | no measurable change (p = 0.223) |
  | Python helper start to ready, no network | 0.27 (0.26 to 0.53) s | 0.30 (0.26 to 0.60) s | +0.03 s, +13.2% | no measurable change (p = 0.675) |
  | Python helper start, CPU | 0.27 (0.25 to 0.34) s | 0.29 (0.25 to 0.39) s | +0.03 s, +11.3% | no measurable change (p = 0.740) |
  | Python helper memory once started | 71.2 (71.1 to 71.3) MB | 71.2 (71.1 to 71.3) MB | +0.0 MB, +0.0% | no measurable change (p = 1.000) |

  Firm in both runs, each at p = 0.002: idle memory (physical footprint)
  rose by 22.2 and 21.0 MB, from about 97 MB to about 118 MB; peak
  memory, launch and history load, by 23.3 and 20.2 MB; and CPU from
  launch to the idle window by 0.11 and 0.09 s.

  Not held across both runs: the memory the app holds allocated was 1.3
  MB higher in the first run (p = 0.002) and showed no measurable change
  in the repeat (+0.1 MB); idle CPU and idle CPU power were possibly
  higher in the first run only; launch to history loaded was 0.03 s
  higher (p = 0.006), and idle memory growth possibly higher, in the
  repeat only. None of those counts without another repeat.

  The memory the app holds allocated is the heap, read after the idle
  window. It rose by 1.3 MB at most, and not in the repeat, while the
  physical footprint rose by 21 to 22 MB, so the extra memory is most likely not the app's
  own objects but memory the system holds for it, such as what it draws
  the window with. Pull request 140, which gave the main window the Glass
  shell with a floating sidebar, was named here as the likeliest cause.
  Measured on its own that night it is not; see pull request 153's entry.
  Under the rule of 2026-11-20 a row that moves and
  holds is followed by measuring the phase's pull requests one by one, so
  pull request 140 is measured on its own next, against pull request 139
  (`c9453fd` against `92145d7`). Whether about 21 MB more is acceptable is
  the owner's decision. The readings, the samples, the rules and the
  scripts are kept beside the results, in
  `build/bench/results/compare-redesign-20261120-221038/conditions` and
  `build/bench/results/compare-redesign-repeat-20261120-230329/conditions`.
- Testing: `docs-check` passes on this pull request's branch. No code
  changes.
- Review: read by its author, with every figure checked against the two
  `report.md` files and the chain logs,
  `build/bench/chain/compare-redesign.log` and
  `compare-redesign-repeat.log`. Both tables were taken from the reports
  by script, without the column that names how each row is read, and
  compared with them again after the edit. No independent review, for a
  record of measurements that changes no code.
- Known issues: the rise of about 21 MB in idle memory, 20 to 23 MB in
  peak memory and 0.09 to 0.11 s in CPU from launch to the idle window
  across pull requests 135 to 150 is not yet put down to any one pull
  request. Pull request 140 is to be measured on its own next.
- Verdict: retained.

### 153: Read Yahoo's chart details with the yfinance the app ships

- What: the Yahoo events lookup of pull request 136,
  `Stockbar/Resources/get_instrument_events.py`, read the chart details
  that yfinance gives (`history_metadata`) only when they were a `dict`.
  yfinance 1.8.0, the version in `requirements.lock`, gives them as its own
  read-only mapping (`HistoryMetadata`), which is not a `dict`. So the
  instrument type was never found and every symbol was thrown away as
  having no data. The lookup had never answered since it was merged. Nothing
  shows its results yet, so nothing on screen was wrong. The offline tests
  passed because their stand-in for yfinance gave plain dicts.

  Both helpers that read those details now accept any mapping. The price
  helper, `get_stock_data.py`, had the same check in `trading_currency()`,
  in the fallback used when Yahoo's quote gives no currency. There it
  returned no currency where the chart had one, and the London suffix rule
  or nothing was used instead.

  Found in the one supervised live run the owner allowed on 2026-11-25 ("run
  the yahoo check"), before Calendar, a local Income estimate and a Funds
  group are built on the lookup. It used twelve public symbols from no
  portfolio, the helper from `381fad1`, and a throwaway environment made
  from `requirements.lock` (yfinance 1.8.0), at 08:58 UTC. Every symbol
  came back "no data", Apple's included. At 08:59 UTC, with the one-line
  fix, the same symbols gave:

  | Symbol | Type | Ex-dividend | Pay date | Earnings | Payments, last 12 months |
  | --- | --- | --- | --- | --- | --- |
  | AAPL | EQUITY | 2026-11-12 | 2026-11-16 | 2027-01-28 | 4, USD |
  | MSFT | EQUITY | 2026-11-19 | 2026-12-10 | 2027-01-27 | 4, USD |
  | KO | EQUITY | 2026-12-01 | 2026-12-15 | 2027-02-09 | 4, USD |
  | SPY | ETF | none | none | none | 4, USD |
  | VOD.L | EQUITY | 2026-11-19 | none | 2026-11-10 | 2, GBP |
  | ULVR.L | EQUITY | 2026-11-12 | none | 2027-02-11 | 4, GBP |
  | HSBA.L | EQUITY | 2026-11-05 | none | 2027-02-23 | 4, GBP |
  | BP.L | EQUITY | 2026-11-12 | none | 2027-02-09 | 4, GBP |
  | VUSA.L | ETF | none | none | none | 4, GBP |
  | VWRL.L | ETF | none | none | none | 4, GBP |
  | CTY.L | EQUITY | none | none | none | 4, GBP |
  | SMT.L | EQUITY | none | none | none | 2, GBP |

  So US shares have every date, London shares have the ex-dividend and
  earnings dates but never a pay date, and ETFs and investment trusts have
  no dates at all, only their last year's payments. Investment trusts come
  back as EQUITY. The ex-dividend date is the latest one Yahoo knows and is
  often past. No rate limit was met. The finding is kept in
  `build/design/findings/yahoo-events-check-2026-11-25.md`.

  This entry also records pull request 140's own comparison, owed by
  [pull request 151's entry](#151-record-the-redesign-benchmark-and-bring-the-log-up-to-date),
  and corrects two of that entry's sentences.
- Merged: 2026-11-25, squash commit `6e7184d`. The merge published
  experimental build 382.3.21 as the prerelease `experimental-382.3.21`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark's
  launches make no Yahoo request. The price helper, whose start it
  measures, gains one standard-library import.

  **Pull request 140's comparison**, run at 01:01 UTC on 2026-11-21 by the
  same script as the redesign's, after twenty quiet minutes on mains
  power: before `c9453fd` (pull request 139), after `92145d7` (pull
  request 140), six launches a side in turns, on macOS 27.2.1 and an Apple
  M3 Pro with 18 GB, the lid open and the screen unlocked. No reading inside
  the turns showed input. The four busiest processes together averaged
  105% of a core over the before side's 16 readings and 97% over the after
  side's, a ratio of 1.08. No measured segment had another project's
  build beside it. The run stands; it was not repeated.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 114.9 (111.4 to 120.6) MB | 116.4 (107.5 to 117.7) MB | +1.5 MB, +1.3% | no measurable change (p = 0.937) |
  | Idle memory the app holds allocated | 53.7 (52.8 to 54.3) MB | 50.3 (50.0 to 51.8) MB | -3.4 MB, -6.3% | lower (p = 0.002) |
  | Peak memory, launch and history load | 253.8 (252.3 to 255.5) MB | 273.3 (264.3 to 277.6) MB | +19.5 MB, +7.7% | higher (p = 0.002) |
  | Idle memory growth across the window | 0.0 (0.0 to 0.3) MB | 0.3 (0.0 to 0.6) MB | +0.3 MB | possibly higher (p = 0.045) |
  | Idle CPU | 0.084 (0.070 to 0.106) s/min | 0.103 (0.092 to 0.105) s/min | +0.020 s/min, +24.0% | no measurable change (p = 0.058) |
  | Idle CPU wake-ups | 26 (23 to 28) /min | 26 (25 to 28) /min | +0 /min, +2.0% | no measurable change (p = 0.675) |
  | Idle CPU power | 3.71 (3.48 to 3.97) mW | 3.85 (3.58 to 4.04) mW | +0.13 mW, +3.5% | no measurable change (p = 0.180) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | +0.000 MB/min | no measurable change (p = 1.000) |
  | Launch to first window | 0.47 (0.45 to 0.52) s | 0.44 (0.42 to 0.51) s | -0.03 s, -7.4% | possibly lower (p = 0.043) |
  | Launch to history loaded | 0.58 (0.55 to 0.64) s | 0.58 (0.55 to 0.61) s | -0.01 s, -0.9% | no measurable change (p = 0.874) |
  | CPU from launch to the idle window | 1.72 (1.68 to 1.74) s | 1.74 (1.68 to 1.76) s | +0.02 s, +1.2% | no measurable change (p = 0.297) |
  | CPU energy from launch to the idle window | 5.45 (5.34 to 5.55) J | 5.24 (5.15 to 5.40) J | -0.21 J, -3.8% | lower (p = 0.009) |
  | Python helper start to ready, no network | 0.26 (0.25 to 0.99) s | 0.42 (0.25 to 0.71) s | +0.16 s, +61.5% | no measurable change (p = 0.576) |
  | Python helper start, CPU | 0.26 (0.25 to 0.37) s | 0.32 (0.25 to 0.47) s | +0.06 s, +23.1% | no measurable change (p = 0.450) |
  | Python helper memory once started | 71.2 (71.1 to 71.3) MB | 71.1 (70.6 to 71.3) MB | -0.1 MB, -0.1% | no measurable change (p = 0.426) |

  Pull request 140 accounts for most of the rise in peak memory at launch,
  but not for the rise in idle memory or in CPU from launch to idle:
  before it, `c9453fd` already idles at about 115 MB against about 97 MB at
  `5fa923b`. The rows marked lower and possibly were not named and are not
  repeated, so they do not count. The saved footprint of every launch
  shows where the idle rise is: the `CoreAnimation` region, the system's
  drawing memory for the app, is 3.2 MB in every launch of `5fa923b` and
  22 MB in every launch of `c9453fd`, `92145d7` and `2d5d992`. Pull
  requests 135 and 136 change no view, so the rise is in 137, 138 or 139.
  They are to be measured one at a time next. The report is
  `build/bench/results/compare-pr140-20261121-005920/report.md`, with its
  readings under `conditions`, and the log is
  `build/bench/chain/compare-pr140.log`.
- Testing, on macOS 27.2.1: `python-tests` passes, 104 tests. Two of them
  are new or extended. In `PythonTests/test_get_instrument_events.py`, every
  stand-in ticker now gives its chart details as a read-only mapping that
  is not a dict, the way yfinance 1.8 does, and a new test checks that a
  symbol is answered from one. In `PythonTests/test_get_stock_data.py`,
  `trading_currency()` is given one too. With either helper's old dict-only
  check put back, the tests fail: 20 for the events helper (10 failures, 10
  errors) and 1 for the price helper. `checks`, `docs-check` and
  `build-release` pass, 999 XCTest tests pass with 0 failures, and the 95
  script tests pass. CI does not run for this branch, so these were run
  locally.
- Review: by its author. The live result is the evidence; no independent
  review, for a one-line change to each helper.
- Known issues:
  - The events lookup's results are not shown on any screen yet, so the
    fix is checked by the live run and the tests, not on screen.
  - The rise in idle memory is still not put down to one pull request.
- Verdict: retained.

### 154: Allocation: a Cash row, so its shares match Holdings' weights

- What: Allocation gave each group's share of the holdings' total, while
  Holdings' Weight column gives each holding's share of the net value,
  cash included, or Folync's own figure. The same holding showed two
  percentages on two pages: in the made-up portfolio VUSA was 26.4% on
  Allocation and 25.5% on Holdings. The owner chose on 2026-11-25 to add a
  Cash row.

  When the portfolio's source gives cash above zero, each of the three
  views (Sector, Holding, Currency) has a row and a slice named "Cash",
  shown last and never folded into "Other". Every share on the page is
  then of holdings plus cash. The donut's centre gives that total, with
  "9 holdings and cash" under it. Cash comes from a new
  `DataModel.netValueCash()`, which picks its source exactly as
  `calculateNetValue()` does: Folync's `cash` figure, or the cash in a
  fresh Trading 212 account snapshot. It is taken only in the currency
  the source names and converted at a current rate. Without either, cash
  counts as not known and nothing is worked out from totals. A local
  portfolio has none, so its page is as before.

  Cash at zero has no row. Cash below zero has no slice, the shares stay
  of the holdings alone, and a line under the chart gives the figure and
  says so. Cash has no sector and no day's change: its change cell is
  "–", and VoiceOver reads "Cash, £2,940.18, 3.5 percent". It has the only
  tooltip on the page. Its colour is a new token, `allocationCash`: dark
  ink on a light card and pale parchment on a dark one, neither red nor
  green nor the grey of "Other" and Unclassified.

  Diversification and the correlation grid stay holdings-only. A caption
  says so, and their notes say "of the holdings' value". The Unclassified
  note gives the Unclassified row's own share and adds "cash included".
  The valuation code moved unchanged from the view into
  `AllocationValuation`, so the agreement with Holdings could be tested.
- Merged: 2026-11-25, squash commit `c361a5a`. The merge published
  experimental build 382.3.22 as the prerelease `experimental-382.3.22`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark's
  launches open the Overview and never this page.
- Testing, on macOS 27.2.1 and Xcode 27.2: after pull request 153 was
  merged this branch was brought up to date with it, and the figures here
  are for all of it together: 1012 XCTest tests with 0 failures.
  Thirteen are new, in `AllocationCashTests` in
  `PortfolioAnalyticsServicesTests.swift`. They cover:
  - the row in each view, its size and its place;
  - no row with no cash, with zero cash, or with cash below zero, and
    that line's text;
  - shares adding up to 100%;
  - the centre and its caption, the VoiceOver text, and the tooltip;
  - Cash never folded into "Other";
  - the colour token and where the cash comes from;
  - each holding's share equal to its Holdings weight, for a local
    portfolio and for a Folync one with cash.

  Six temporary breakages were each caught and removed:
  - cash folded into "Other";
  - shares not taken again over holdings plus cash;
  - cash taken from the total value instead of the cash figure;
  - cash below zero treated as held;
  - the Cash row speaking a day's change;
  - the caption without "and cash".

  `checks`, `docs-check` and `build-release` pass, PY1012 Python helper
  tests and 95 script tests pass. CI does not run for this branch, so
  these were run locally.

  On screen, in the acceptance copy with the stand-in's made-up portfolio
  (£2,940.18 of cash): each view in dark and light, at the default and the
  minimum size, before and after, with nothing cut off. The seven holdings
  shown in the Holding view match their Holdings weights to the shown
  0.1% (VUSA 25.5%, NVDA 15.4%, MSFT 11.7%). The largest unrounded
  difference is 0.000035 points, from Folync's weight being rounded to
  four places. Made a local portfolio, the page has no Cash row. Captures
  are in `build/design/shots/D3b/`.
- Review: written by an Opus worker from the session lead's
  specification (`build/design/specs/D3b-allocation-cash.md`). The session
  lead read the cash sourcing against `calculateNetValue()`, the
  presentation code and the colour token, and looked at the captures of
  the Holding view in dark and the Sector view in light at the minimum
  size. It did not read every test. No independent second review.
- Known issues:
  - **Trading 212 agreement is not established.** Holdings values a
    Trading 212 position at the broker's figure; Allocation values it at
    price times units. Where those differ, the two pages' percentages
    differ too, as before this change. With cash below zero they differ
    for Trading 212 even without that: Holdings divides by the account
    value and Allocation by the holdings.
  - A Folync holding that Stockbar does not show or cannot value still
    counts in Folync's total, so Folync's weights could then differ from
    Allocation's.
  - Cash's change cell is "–", the app's usual mark for an unknown figure,
    while this page's other unknown day changes keep "—".
  - The Currency view puts every Folync holding under the currency Folync
    values it in (GBP in the made-up portfolio), as before.
  - The local portfolio capture shows no rows at all, because the copy
    fetches no prices; it shows that there is no Cash row and no more.
  - The tooltip was not seen on screen.
  - The worker's accessibility reads twice returned the copy's own menu
    bar, against the rule to read the window only, and the copy became
    the active app once, after its own sheet was confirmed. Nothing else
    was touched.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 155: Allocation's Cash row: one source for holdings, total and cash

- What: two independent reviews of pull requests 153 and 154, by GPT-6.2
  Astra and Gemini 4 Neon, found that Allocation's Cash row could still
  disagree with Holdings, or show what it should not. The two reviews
  agreed on every main point, and the session lead checked them against
  the code. This pull request fixes them. It also fixes a fault the
  reviews found next to pull request 153.

  **One source.** A new `DataModel.holdingsWeightBasis()` decides once
  where Holdings' total and cash come from: Folync whenever its snapshot
  is there, then a fresh Trading 212 account, then the local portfolio.
  With Folync's holdings, the cash is Folync's or not known. Before, a
  Folync snapshot with no total took a leftover Trading 212 account's
  cash. Each holding's value comes from `weighedPositionValue(for:)`, the
  code behind Holdings' weight, moved out unchanged. Allocation uses both,
  so a Trading 212 position is now valued at the broker's figure on both
  pages.

  **When there is no Cash row.** A Cash row is shown only when all four
  hold:
  - the source's holdings and total match;
  - every holding is valued (a holding known to be worth nothing counts
    as valued and has no slice);
  - every figure has a loaded exchange rate into the total's currency
    (pence go through pounds at a fixed 100);
  - holdings plus cash, converted into the total's currency, come to the
    source's total within the larger of 0.05% of it, or half the
    currency's smallest unit for each figure summed.

  The allowance is set so that every share shown to 0.1% agrees with
  Holdings. A rounding penny cannot hide the cash, and a difference too
  small to change any shown share may pass. When the check passes, every
  share is of the source's own total.

  Otherwise the shares are of the holdings, and a line under the chart
  says why: Folync gives no total, holdings are kept outside the Trading
  212 account, some holdings have no price, there is no rate for the
  cash, or the figures do not add up.

  **Also:**
  - The allocation card now shows with one holding, or with cash alone
    (100% Cash, "Cash only").
  - Conversions on the page use a new
    `CurrencyConverter.convertWithLoadedRates`, which never uses a built-in
    fallback rate.
  - The page recalculates when rates load.
  - Cash that would display as zero counts as zero.
  - With cash below zero or left out, every percentage note says "of the
    holdings' value".
  - The Cash row's change cell uses the page's own "—".
  - The Currency view groups a Folync holding by the currency it is
    priced in, not the one Folync values it in. In the made-up portfolio
    that view was GBP 96.5% and Cash 3.5%; it is now GBP 59.8%, USD 36.7%
    and Cash 3.5%.
  - The Folync holdings are looked up once per recalculation instead of
    once per row.
  - The page recalculates when the loaded rates change, not on every
    refresh that brings the same rates.

  **Python.** When yfinance's `info` fails after the chart has loaded, both
  the real-time and the previous-close paths of `get_stock_data.py` now
  still read the chart's currency. Before, a London listing quoted in
  pounds fell to the pence rule and was divided by 100. The remaining
  `dict` checks on `info` and `calendar` accept any mapping.

  Holdings itself is not changed. The worker reported these inconsistencies
  in it, left for a later decision:
  - Trading 212 with a manual holding beside it: the weights add up to
    more than 100%.
  - Folync with no total: the net value is not a total of its rows.
  - Broker positions linked to no row are counted in the account's value.
  - Folync holdings hidden for tiny share counts still count in Folync's
    total.
  - Holdings still converts with built-in fallback rates.
  - With cash below zero, the weights add up to more than 100%.
- Merged: 2026-11-25, squash commit `f925fae`. The merge published
  experimental build 382.3.23 as the prerelease `experimental-382.3.23`.
  Checked after it: the release workflow succeeded and the prerelease is
  listed. The published archive was not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark's
  launches never open this page. The price helper's change adds no work
  when `info` succeeds.
- Testing, on macOS 27.2.1 and Xcode 27.2, on the last commit, which is
  on the current head of `experimental`: 1028 XCTest tests with 0
  failures, 29 of them in `AllocationCashTests`. The tests go through
  `holdingsWeightBasis()`, `AllocationValuation.make(from:)` and Holdings'
  own weight for each source. That covers Folync with and without a
  total; Trading 212, alone and with a manual holding; local; EUR missing
  from a loaded rate table; partial coverage; cash only; one holding; tiny
  cash; borrowing; mixed currencies, pence against pounds, and the
  allowance; a holding worth nothing or less; and the Currency view's
  grouping. The Folync fixtures go through the production decoder, and the
  rates test reads the trigger the page itself keys on. Python helper
  tests: 108, four of them new.

  Twenty-three temporary breakages were each caught and removed: fifteen
  in the first round (eleven in Swift, four in Python) and eight in the
  second. One of them, `info` checked as a `dict` again,
  was caught by nothing until a test was added. `checks`, `docs-check`
  and `build-release` pass, and so do 95 script tests. CI does not run for
  this branch, so these were run locally.

  On screen, in the acceptance copy: the three views of the made-up
  Folync portfolio look as pull request 154 left them, except for the
  Cash row's dash and the Currency view's new grouping. Captures are in
  `build/design/shots/D3c/`, the second round's named `round2-*`.
- Review: written by an Opus worker from the session lead's
  specification (`build/design/specs/D3c-allocation-cash-fixes.md`), which
  was drawn from the two reviews. GPT-6.2 Astra then reviewed the first
  round's five commits. It confirmed each earlier fault fixed and Holdings'
  weights unchanged, and found five more faults in the new check and two
  that predate it. A second Opus worker fixed them on the same branch. The
  session lead read the source decision, the change to Holdings' weight
  and the second round's check against the total. The second round had no
  independent review.
- Known issues:
  - The cash-only, single-holding, partial-coverage and "left out" states
    were never seen on screen, only in tests. The stand-in cannot give an
    unvalued holding without its data being edited.
  - Trading 212 with no cash figure, or zero cash, gives no line, so its
    shares can differ from Holdings' without saying so.
  - A Trading 212 account holding only cash never fetches its account
    summary in ordinary sync while hourly reconciliation is off, so
    Allocation has no cash to show for it. Found in review; not changed.
  - That the page's task re-runs when rates change rests on a test of the
    trigger value it keys on, not on a test of the task itself.
  - A change to only the Trading 212 snapshot's cash waits for the next
    trade update before the page recalculates.
  - The worker's first two window reads also returned the acceptance
    copy's own menu bar, against the rule.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 156: Trading 212: value a cash-only account, and only the account in use

- What: a Trading 212 account with no linked holdings never fetched its
  account summary in the ordinary sync (`syncLinkedTrading212Holdings`
  returned before asking the broker anything). With the hourly check off,
  which is the default, such an account had no value: no net value, and no
  cash for Allocation's Cash row (pull request 155).

  Now, when Trading 212 is enabled with a supported account type and its
  credentials load, and nothing is linked under the account in use, each
  ordinary sync asks for the account's summary, one request. It stores a
  valuation with no positions, marked account-only. Such a valuation
  stands only while Stockbar holds no holdings of its own. Beside holdings
  entered by hand, no request is made, the old "No linked Trading 212
  holdings found" reason stays, and a valuation stored earlier stops
  applying as soon as a holding is added. A test showed what this guards
  against: without it, a manual holding's 100% weight fell to 16%.

  For a cash-only account, Holdings' net value is the cash, the menu bar
  and popover show it, and Allocation shows one Cash row at 100% ("Cash
  only"). An account whose summary includes investments not linked here
  is valued at the whole account. Holdings then says so above its empty
  table, and Allocation gives the reason it draws nothing. Without an
  investments figure, the Overview's cost basis and gain are unknown ("-"),
  not worked out from the cash.

  **Review.** Two independent reviews of the first version, by GLM 5.4 and
  Gemini 4 Neon, found faults that a second round fixed. Several of them
  predate this pull request and affected linked accounts too:
  - links in another Trading 212 account counted as links in the one in
    use (predated);
  - the hourly check stored a valuation that overrode hand-entered
    holdings' figures (predated);
  - a leftover Trading 212 valuation showed through a Folync portfolio
    whose total or gain was missing (predated);
  - clearing or changing the credentials, turning Trading 212 off, or
    choosing another environment or account type left the old account's
    figures on screen for up to 20 minutes (predated);
  - a request still in flight when any of that happened could store its
    answer (partly predated).

  Now only links under the account in use count, every valuation stored
  without such links is account-only, a Folync portfolio never takes a
  Trading 212 figure, and an account change clears the stored valuation
  at once. Every broker answer is checked again before it is stored. It is
  stored only if the task was not cancelled, Folync is not active, Trading
  212 is still on with the same environment and account type, credentials
  are present, and no account change happened meanwhile.

  Allocation now recalculates when the valuation in force changes: its
  account, currency, account value and cash. It no longer recalculates on
  every sync, and it does after a valuation that went stale comes back.
- Merged: 2026-11-25, squash commit `1dcde6f`. The merge published
  experimental build 382.3.24 as the prerelease `experimental-382.3.24`.
  Checked after it: the prerelease is listed. The published archive was
  not downloaded or opened.
- Benchmark: owed, not run, on the rule of 2026-11-20. The benchmark's
  launches have no Trading 212 account.
- Testing, on macOS 27.2.1 and Xcode 27.2, on the last commit, which is on
  the current head of `experimental`: 1052 XCTest tests with 0 failures.
  New tests:
  - nine sync tests;
  - a new `Trading212ValuationAccountTests` class of eleven;
  - `AllocationCashTests`, now 33.

  They use a fake broker, so no request leaves the process. They cover:
  - the cash-only account, and no request without Trading 212 or without
    credentials;
  - holdings beside the account, and a holding added later;
  - links in another account, and the reconcile path;
  - Folync with a leftover valuation, and Folync taking over mid-request;
  - an account change, and a request in flight across one;
  - an unfinished and a failed portfolio load;
  - the trigger, including a valuation that goes stale and comes back;
  - the page's reason lines, and the cost basis.

  Twenty-one temporary breakages were run: ten in the first round and
  eleven in the second. All but one were caught. The uncaught one is
  removing the re-check for a cancelled task: the request itself already
  fails on cancellation, so no test can reach it. `checks`, `docs-check`,
  `build-release` and `python-tests` pass, and so do 95 script tests. CI
  does not run for this branch, so these were run locally.
- Review: written by two Opus workers in turn from the session lead's
  instructions, with independent reviews of the first round by GLM 5.4
  (max) and Gemini 4 Neon. The session lead read the valuation's guard,
  the account-change hooks and the record of each round. The second round
  had no independent review.
- Known issues:
  - Never tried against a real Trading 212 account. The shape of a real
    cash-only summary (whether `investments` is zero or missing) is not
    known; both shapes are tested.
  - Entering a first holding by hand beside a cash-only account makes the
    net value drop from the cash to that holding.
  - The hooks are tested, but not their calls from the settings view and
    the settings import.
  - The flag cleared when a reconciliation imports and links holdings is
    not tested.
  - Nothing here was looked at on screen.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 157: Glass cards: draw the top highlight without an extra copy of the window

- What: the redesign raised the app's idle memory by about 21 MB. Pull
  requests 137 to 139 were measured one launch at a time on 2026-11-25
  (record 155), which placed almost all of it in the system's drawing
  memory for the app, the `CoreAnimation` region of the footprint. It is
  3.2 MB at pull request 136, 19 MB after 137 and 22 MB from 139. A trace
  of the surface effects, one variant per launch, found the single cause:
  the faint highlight along the top of each card in dark mode, drawn as a
  hairline stroked with a gradient. Pull request 139 added the same
  highlight to the Overview's new cards, hence its 3 MB.

  | Variant, dark Overview | `CoreAnimation` |
  | --- | --- |
  | `experimental` at `1dcde6f` | 22 MB |
  | the same, light (light cards have no highlight) | 3.6 MB |
  | no shadow modifier, or a shadow only when it has a colour | 22 MB |
  | no card fill | 22 MB |
  | no highlight | 3.6 MB |
  | the highlight drawn on a `Canvas` | 3.7 MB |
  | the highlight in a `drawingGroup()` | 3.7 MB |
  | **the highlight as a plain hairline under a gradient mask** | **3.6 MB** |

  Shadows and fills cost nothing. Why a gradient-stroked hairline costs a
  window's worth of memory is not known; three other ways of drawing the
  same highlight avoid it. This pull request draws it as a plain hairline
  under a gradient mask, in a small view `StockbarSurfaceHighlight`.

  The owner chose this option on 2026-11-25, from screenshots that put
  the current look, this option and no highlight side by side. The look
  is the same. Compared by pixel at the default size:
  - Holdings and Allocation in dark mode differ by at most 6/255;
  - in light mode they are identical;
  - the Overview's cards differ only at their rounded top corners, by at
    most 5/255, which an eight-times zoom does not show.

  Removing the highlight altogether saves the same memory but visibly
  dims the cards' top edges.
- Merged: 2026-11-25, squash commit `45cd139`. The merge published
  experimental build 382.3.25 as the prerelease `experimental-382.3.25`.
  Checked after it: the prerelease is listed. The published archive was
  not downloaded or opened.
- Benchmark: the one-launch readings above. The timed comparison is owed,
  on the rule of 2026-11-20, and is to cover pull requests 152 to 157
  together. The footprint as a whole moved by up to 9 MB between launches
  with the same `CoreAnimation` figure, so the saving is quoted for that
  region only until the timed comparison is made.
- Testing, on macOS 27.2.1 and Xcode 27.2, on the worker's last commit,
  which is on the current head of `experimental`: 1054 XCTest tests with 0
  failures. Two are new, in `SettingsTransferTests.swift`:
  - one renders the new highlight beside the old gradient stroke and
    checks that no pixel differs by more than 2/255;
  - one checks that the highlight fades out by a third of the way down.

  One temporary breakage failed both. `checks`, `docs-check`,
  `build-release` and `python-tests` pass, and so do 95 script tests.
- Review: traced and written by an Opus worker from the session lead's
  instructions. The session lead read the change and looked at the
  screenshots. No independent review, for a change of one view that is
  pinned by a pixel test.
- Known issues:
  - Memory was measured with the benchmark's page open, the dark
    Overview. Other pages were not measured.
  - About 0.4 MB of today's 3.6 MB against 3.2 MB at pull request 136 is
    not explained.
  - Whether the pixel test holds on another Mac's renderer, and whether
    the saving holds on other macOS versions, is not known.
  - Other gradients drawn elsewhere, such as the chart's area fill, were
    not checked for a similar cost.
  - The two new tests sit in `SettingsTransferTests.swift`, an odd home
    for them.
- Verdict: retained, with its timed benchmark owed.

### 158: Income for a local or Trading 212 portfolio, as a labelled estimate

- What: Income was dimmed with "Needs a Folync portfolio" for any portfolio
  not on Folync. The plan the owner approved on 2026-11-19 says: "Local
  and Trading 212: Income as a labelled estimate". Now, for a local or
  Trading 212 portfolio, Income is built from Yahoo's record of each
  holding's dividends over the last twelve months, times the units held
  today. The events lookup of pull request 136, repaired in 153, supplies
  that record.

  The page has the Folync page's shape: an outlook, a history and a view
  by holding. A notice at the top says the figures are an estimate from
  Yahoo's record at today's units, not a record of what was paid. Nothing
  is called "Received".
  - **The last twelve months:** each payment Yahoo lists, at today's
    units, marked "estimate".
  - **The next twelve months:** the same payments a year on, each row
    marked "Estimate". Where Yahoo gives a real upcoming ex-dividend date,
    it replaces the nearest estimated date within 45 days, and the row
    says "Yahoo's date, amount estimated".
  - **Conversion:** loaded rates only. A holding with no loaded rate keeps
    its own currency's figures, is left out of the totals, and is named
    in a notice.
  - **Yahoo is asked** once when the page is selected and once per press
    of refresh, never on a timer and never from the popover or the
    Overview.
  - **The sidebar** dims Income only when live market data is off.
  - **Unchanged:** Activity and Trades stay Folync-only. The Folync Income
    page is the old view, renamed and otherwise unchanged.

  A new acceptance-only launch option, `STOCKBAR_ACCEPTANCE_EVENTS`,
  gives the events service a fixture file of made-up events instead of
  Yahoo, so the page can be seen in the acceptance copy. It takes effect
  only in an explicit acceptance run. The bootstrap checks the file and
  copies it, owner-only, into the run's root, and the app checks that copy
  again and stops at launch if any check fails. The checks: a regular
  file, owned by the user and readable by no one else, at most 64 KB,
  version 1, and only symbols starting `FAKE`.

  This entry also records the timed comparison owed by pull requests 152
  to 157, and the merge of 157.
- Merged: 2026-11-25, squash commit `0c77a54`. The merge published
  experimental build 382.3.26 as the prerelease `experimental-382.3.26`.
  Checked after it: the prerelease is listed. The published archive was
  not downloaded or opened.
- Benchmark: this pull request's own comparison is owed, on the rule of
  2026-11-20. The benchmark's launches never open Income and make no Yahoo
  request.

  **The comparison owed by pull requests 152 to 157**, run at the owner's
  request on 2026-11-25 instead of overnight: before `2d5d992` (the last
  commit measured, record 151), after `45cd139` (pull request 157). Six
  launches a side, in turns, on macOS 27.2.1 and an Apple M3 Pro with 18
  GB, on mains power, with the lid open, the screen unlocked and no other
  project's build present. Each run started after twenty quiet minutes and
  stood under all three set-aside rules.

  First run: turns from 20:53 to 21:27 UTC. The four busiest processes
  together averaged 135% of a core on the before side and 126% on the
  after side, a ratio of 1.08. No reading showed input, and no segment had
  another build beside it.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 118.2 (113.0 to 122.3) MB | 100.1 (94.1 to 103.9) MB | -18.1 MB, -15.3% | lower (p = 0.002) |
  | Idle memory the app holds allocated | 54.3 (51.5 to 54.9) MB | 52.8 (51.5 to 53.7) MB | (-1.5 MB, -2.8%) | no measurable change (p = 0.121) |
  | Peak memory, launch and history load | 267.9 (262.9 to 277.9) MB | 251.5 (241.2 to 259.6) MB | -16.4 MB, -6.1% | lower (p = 0.002) |
  | Idle memory growth across the window | 0.3 (-1.6 to 0.5) MB | 0.2 (0.2 to 0.4) MB | (-0.0 MB, -16.7%) | no measurable change (p = 0.955) |
  | Idle CPU | 0.101 (0.091 to 0.109) s/min | 0.100 (0.092 to 0.111) s/min | (-0.001 s/min, -1.0%) | no measurable change (p = 0.970) |
  | Idle CPU wake-ups | 26 (24 to 28) /min | 26 (23 to 29) /min | (+0 /min, +0.0%) | no measurable change (p = 0.855) |
  | Idle CPU power | 4.32 (3.69 to 5.00) mW | 4.38 (4.20 to 4.85) mW | (+0.05 mW, +1.3%) | no measurable change (p = 0.732) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | (+0.000 MB/min) | no measurable change (p = 1.000) |
  | Launch to first window | 0.58 (0.53 to 0.96) s | 0.59 (0.45 to 1.02) s | (+0.01 s, +0.9%) | no measurable change (p = 0.699) |
  | Launch to history loaded | 0.71 (0.62 to 0.95) s | 0.74 (0.60 to 0.98) s | (+0.02 s, +2.8%) | no measurable change (p = 0.974) |
  | CPU from launch to the idle window | 1.96 (1.85 to 2.18) s | 1.96 (1.85 to 2.07) s | (+0.00 s, +0.0%) | no measurable change (p = 0.922) |
  | CPU energy from launch to the idle window | 5.96 (5.72 to 6.43) J | 5.92 (5.78 to 6.11) J | (-0.04 J, -0.7%) | no measurable change (p = 0.729) |
  | Python helper start to ready, no network | 0.29 (0.28 to 0.55) s | 0.28 (0.27 to 0.54) s | (-0.01 s, -5.1%) | no measurable change (p = 0.437) |
  | Python helper start, CPU | 0.29 (0.28 to 0.34) s | 0.28 (0.27 to 0.35) s | (-0.01 s, -3.4%) | no measurable change (p = 0.682) |
  | Python helper memory once started | 71.0 (71.0 to 71.1) MB | 71.1 (71.0 to 71.2) MB | (+0.0 MB, +0.1%) | no measurable change (p = 0.675) |

  Repeat: turns from 21:48 to 22:20 UTC. The ratio was 1.23. One reading
  showed input in the minute before, which is within the rule's limit of
  two. No segment had another build beside it.

  | Metric | Before: median (range) | After: median (range) | Change | Verdict |
  | --- | --- | --- | --- | --- |
  | Idle memory (physical footprint) | 117.5 (107.2 to 123.2) MB | 100.9 (99.3 to 102.6) MB | -16.5 MB, -14.1% | lower (p = 0.002) |
  | Idle memory the app holds allocated | 54.0 (50.1 to 55.0) MB | 53.7 (52.1 to 53.9) MB | (-0.2 MB, -0.5%) | no measurable change (p = 0.519) |
  | Peak memory, launch and history load | 268.9 (261.5 to 280.1) MB | 246.9 (243.4 to 254.1) MB | -21.9 MB, -8.2% | lower (p = 0.002) |
  | Idle memory growth across the window | 0.4 (0.2 to 0.6) MB | 0.3 (0.2 to 0.4) MB | (-0.1 MB, -12.5%) | no measurable change (p = 0.232) |
  | Idle CPU | 0.103 (0.086 to 0.114) s/min | 0.103 (0.099 to 0.107) s/min | (-0.001 s/min, -0.5%) | no measurable change (p = 1.000) |
  | Idle CPU wake-ups | 26 (25 to 28) /min | 26 (25 to 28) /min | (+0 /min, +0.0%) | no measurable change (p = 1.000) |
  | Idle CPU power | 4.12 (3.95 to 4.35) mW | 4.09 (3.62 to 4.35) mW | (-0.03 mW, -0.7%) | no measurable change (p = 0.461) |
  | Idle disk writes | 0.000 (0.000 to 0.000) MB/min | 0.000 (0.000 to 0.000) MB/min | (+0.000 MB/min) | no measurable change (p = 1.000) |
  | Launch to first window | 0.52 (0.49 to 0.88) s | 0.52 (0.49 to 0.53) s | (-0.01 s, -1.0%) | no measurable change (p = 0.801) |
  | Launch to history loaded | 0.64 (0.60 to 0.90) s | 0.62 (0.60 to 0.66) s | (-0.01 s, -1.6%) | no measurable change (p = 0.660) |
  | CPU from launch to the idle window | 1.96 (1.83 to 1.99) s | 1.96 (1.82 to 1.99) s | (-0.00 s, -0.3%) | no measurable change (p = 0.983) |
  | CPU energy from launch to the idle window | 5.99 (5.79 to 6.29) J | 5.94 (5.58 to 5.97) J | (-0.05 J, -0.9%) | no measurable change (p = 0.331) |
  | Python helper start to ready, no network | 0.28 (0.27 to 0.54) s | 0.29 (0.28 to 0.53) s | (+0.01 s, +3.6%) | no measurable change (p = 0.446) |
  | Python helper start, CPU | 0.28 (0.27 to 0.34) s | 0.29 (0.27 to 0.34) s | (+0.01 s, +3.6%) | no measurable change (p = 0.870) |
  | Python helper memory once started | 71.0 (71.0 to 71.1) MB | 71.0 (71.0 to 71.3) MB | (+0.0 MB, +0.0%) | no measurable change (p = 0.708) |

  Firm in both runs: idle memory fell by 18.1 and 16.5 MB, from about 118
  MB to about 100 MB, and peak memory at launch fell by 16.4 and 21.9 MB.
  The drawing memory (`CoreAnimation`) was 22 MB in every before launch
  and 3.6 MB in every after launch, as pull request 157 predicted.
  Nothing else changed measurably in either run, so pull requests 152 to
  156 cost nothing the benchmark can see.

  Idle memory is now about 100 MB, against 97 MB before the redesign. The
  reports are `build/bench/results/compare-pr152-157-20261125-205340/report.md`
  and `compare-pr152-157-repeat-20261125-214806/report.md`.
- Testing, on macOS 27.2.1 and Xcode 27.2, on the last commit, which is
  on the current head of `experimental`: 1075 XCTest tests with 0
  failures. New tests:
  - `StockbarLocalIncomeTests`, now 16, two added by the session lead
    after review;
  - `StockbarAcceptanceEventsFixtureTests`, 4;
  - one in `InstrumentEventsServiceTests`.

  They cover:
  - the windows, the year-on repeat, Yahoo's dates replacing estimated
    ones, and a payment Yahoo lists as coming not being counted twice;
  - holdings with no payments, no answer, or no rate;
  - every "estimate" label;
  - the sidebar for Folync, local, Trading 212 and providers off;
  - the acceptance option's gate.

  Eleven temporary breakages were each caught and removed: nine by the
  worker, and one for each of the session lead's two fixes. `checks`,
  `docs-check`, `build-release` and `python-tests` pass, and 95 script
  tests pass. CI does not run for this branch, so these were run locally.

  On screen, in the acceptance copy made a local portfolio with the new
  fixture (five made-up holdings in pounds, dollars and euros): the
  outlook, history and by-holding views in dark and light, at the default
  and the minimum size, nothing cut off. The sidebar shows Income no
  longer dimmed, and the Folync portfolio's Income page is unchanged.
  Captures are in `build/design/shots/C4/`.
- Review: written by an Opus worker from the session lead's
  specification (`build/design/specs/C4-local-income.md`). GLM 5.4 (max)
  reviewed it independently and found no bug. It confirmed that the
  acceptance option cannot be reached outside an explicit run, that Yahoo
  is asked only as intended, and that the Folync page is unchanged. Of
  its findings, the session lead fixed two that change figures:
  - a payment Yahoo lists as still to come was also counted as last
    year's repeat, so twice (possible when the helper's day is ahead of
    the user's);
  - an estimated row already on Yahoo's exact ex-date was not given
    Yahoo's pay date.

  The session lead also fixed a test that rechecked a first result
  instead of the second. A review by Gemini 4 Neon was stopped by the
  owner before it reported.
- Known issues:
  - By holding's next date can be a pay date for a payment counted in the
    last twelve months (ex-dividend past, payment still to come).
  - A Yahoo date with no payment to attach to shows "–" beside its pill,
    and a holding with no payments last year but an upcoming date reads
    "None" beside that date.
  - Selling everything while the page is open leaves it at £0.00, not "No
    holdings to estimate". A holding added while the page is open shows
    "–" as if Yahoo had not answered, until refresh.
  - With no rate table loaded, a foreign holding keeps "no rate loaded"
    until something else redraws the page.
  - "Never on a timer" and "never from the popover or the Overview" are
    tested by construction only. The positive half of the events
    service's availability, the 64 KB cap and the owner check have no test.
  - Never run with real Yahoo data or for a Trading 212 account. Exchange
    rates were not loaded in the copy, so a converted foreign holding was
    not seen.
  - The worker's accessibility reads three times returned its copy's own
    menu bar, against the rule.
- Verdict: retained, with its benchmark owed, on the rule of 2026-11-20.

### 160: A footer test that accepts either wording of the minutes

- What: the promotion of `experimental` into `testing`
  ([pull request 159](https://github.com/jayjay181818/StockBar/pull/159))
  ran CI on this work for the first time since pull request 133. On Xcode
  27, one test failed:
  `StockbarMainWindowShellTests.testTheFooterSaysWhereThePortfolioComesFromAndHowFreshItIs`.
  It expected the sidebar footer to say "Updated 3 min…" for an update
  three minutes old. The system's relative date formatter on CI's macOS
  says "Updated 3m ago" instead. Both are the system's own wording of the
  same thing, and the app passes on whatever the system gives, so the
  fault is in the test. It now checks that the text starts "Updated 3" and
  ends "ago". Nothing in the app changes.
- Merged: 2026-11-26 as `21a1ed2` (build 382.3.27).
- Benchmark: none needed. Only a test changes.
- Testing, on macOS 27.2.1 and Xcode 27.2: the test's class,
  `StockbarMainWindowShellTests`, 15 tests with 0 failures. `docs-check`
  passes. The rest of the suite is unchanged from pull request 158's 1075
  tests with 0 failures. CI runs on the promotion pull request once it is
  brought up to this commit.
- Review: by its author. No independent review, for a one-line change to
  a test.
- Known issues: other tests may hold system wording in the same way. CI
  found only this one.
- Verdict: retained.

### 161: Bring `testing` back into `experimental` and record the third promotion

- What: the [third promotion](#third-promotion-to-testing-2026-11-26)
  recorded, with "Where things stand", the merge line of pull request 160
  and a row in "Who did what" brought up to date. The branch starts from
  `testing` at `9cb4276`, the promotion's merge commit, so merging it
  brings that commit into `experimental`. Only this file changes.
- Merged: 2026-11-26 with a merge commit, `8fb23f8`, the exception to the
  squash rule described under [How this branch works](#how-this-branch-works).
  `9cb4276` is now in `experimental`.
- Benchmark: no before/after run. `9cb4276` has the files of `21a1ed2`,
  and this pull request changes only this file, so the app is the same.
- Testing: `docs-check` passes on this branch. The tests of the promoted
  commit are under the third promotion.
- Review: read by its author, with each figure checked against the
  published build and the pull requests it names.
- Known issues: it should have followed the promotion straight away, as
  the branch's rules say; it came a day later. No experimental build was
  published in between.
- Verdict: retained.

### 162: Settings and Alerts as mocked; Backups and Diagnostics checked

- What: the last of the plan's "redesigned as mocked" and "restyled only"
  screens, as one tidy. Every control and behaviour stays; nothing without
  a feature behind it is added (no Reminders card, no Calendar or Returns
  rows, no Portfolio picker).
  - Settings: every tab's content starts at the page header's left edge
    and stops at one width, 700 points
    (`StockbarLayout.settingsContentWidth`); section titles match. The five
    grouped-form tabs keep macOS's own grouped rows, widened past the
    form's built-in margin so their groups line up. Their fill still
    differs from Connections' Glass cards: macOS ignores a row background
    on grouped forms.
  - Connections: "API Keys" is now "Market-data keys", with each row's
    status in words ("Not set", "Not verified", "Verified", "Verification
    failed") beside the field. Folync's status is a pill, its fields a
    grid and its buttons a row that wraps (`StockbarWrappingRow`); its
    schedule is one line, "Last checked 9:41, next 9:42". The "What
    Stockbar reads from Folync" rows are tidied and stay in one column, as
    record 145 chose. Trading 212's note is a pill. "Fetch Priority" is now
    "Fetch order". "Use Local Portfolio…" is unchanged.
  - Alerts: the condition icon sits in a tinted ring, grey when paused;
    the controls line up across rows; "Triggered … ago" is easier to read;
    the subtitle matches the mock-up. The page had never been seen with
    alerts in it.
  - `STOCKBAR_ACCEPTANCE_ALERTS`, an acceptance-only fixture of made-up
    alerts behind the same gate as the events fixture. While it is in use
    the alert service stores nothing, checks no price and makes no
    notification-centre call, so macOS is never asked for permission.
  - Diagnostics: ordinary log lines were drawn in the accent blue; they are
    now the primary text colour, and debug lines secondary. The log card
    has the standard padding. Backups had no fault.
- Merged: 2026-11-26 as `9a2c046` (build 382.31.3).
- Benchmark: owed, under the rule for the redesign. No surface, shadow or
  gradient is added, and Settings, Alerts and Diagnostics are not drawn at
  launch, so the single-launch drawing-memory check was not run.
- Testing, on macOS 27.2.1 and Xcode 27.2: 1086 XCTest tests with 0
  failures; `checks`, `docs-check` and `build-release` pass; the Python
  helper tests and the 95 Scripts tests pass. New tests cover the fixture's
  gate and refusals, that fixture alerts are never stored, checked or
  notified, the schedule line, each alert row's text and the log line
  colours; eight temporary breakages were each caught and removed.
  Captures, before and after, in dark and light, at the default and the
  minimum size, are in `build/design/shots/D5/`, with one of Connections
  at full width for the owner to compare.
- Review: by the session lead against the captures and the diff. It added
  "Not set" for a key that has none, which had read "Not verified".
- Known issues: at 700 points Folync's last button wraps to a second line
  at the default size; full-width cards, as on the other pages, would
  avoid it and are the owner's choice. The worker could not click in its
  copies (the screen was locked), so it compiled an uncommitted aid into
  its captured builds to pick tabs and, for the local-portfolio captures,
  switched Folync off itself rather than through the copy's sheet. A few
  "before" captures at the minimum size are missing. A stored key's
  "Verification failed" row was not seen. The acceptance-only Keychain
  items left by this and earlier workers' copies, 261 in all, were removed
  on 2026-11-26 with the owner's leave; the app's own item was not touched.
- Verdict: retained.

### 163: Risk: a reading for the Sortino ratio

- What: the Sortino ratio's tile on the Risk page gets a reading, as the
  Sharpe ratio's has, for example "Good, counting only the falls". Before
  the redesign the page coloured both ratios in the same bands; the
  redesign kept Sharpe's reading and dropped Sortino's colour, and the
  owner asked for the word back. The reading uses the Sharpe ratio's
  thresholds, unchanged (`RiskAnalyticsText.sortinoReading`). With no
  falling days the tile still says "No falling days". Also the merge line
  of pull request 162.
- Merged: 2026-11-26 as `be6ff84` (build 382.31.4).
- Benchmark: none needed. One line of text on a page that is not drawn at
  launch.
- Testing, on macOS 27.2.1 and Xcode 27.2: 1086 XCTest tests with 0
  failures; `checks` and `docs-check` pass. The Risk page's tests now
  expect the reading under Sortino for the three series kept from before
  the redesign, and check the thresholds, the missing ratio and an
  infinite one. No Python or release-build change, so those checks were
  not rerun.
- Review: by its author.
- Known issues: none known.
- Verdict: retained.

### 164: Calendar, and "Next up" in the popover and on the Overview

- What: the plan's C2. A Calendar page after Income in the sidebar, with the
  "New" badge, and "Next up" (up to three events in the next fourteen days)
  in the popover and as cards on the Overview. ⌘-numbers follow the sidebar,
  as before, so those after Income move down one.
  - Dividends: for a Folync portfolio, Folync's dividends route with the
    Income page's own query, so one request serves both pages; pills from
    Folync's `dateCertainty` ("Declared", "Estimated", otherwise
    "Upcoming"). For a local or Trading 212 portfolio, the Income page's
    estimate from Yahoo's record: funds and trusts get last year's dates a
    year on, marked "Estimated" (the owner's choice of 2026-11-26).
  - Earnings: Yahoo's dates through the events service, marked as Yahoo's;
    a range is "Estimated". For a Folync portfolio this sends the holdings'
    ticker symbols, not amounts, to Yahoo for the first time, as the plan's
    interim rule allows until Folync has an events route.
  - Upcoming and Past views, a month grid (each day with events a button
    with one VoiceOver sentence) and a list grouped This week, Next week and
    by month. Past lists dividends only (the lead's recommendation; the
    owner's answer is awaited).
  - "Next up" reads only what is saved: the dividends page the fetch policy
    keeps or Folync's copy on disk, and the events service's saved copies.
    Opening the popover or the Overview asks nothing; with nothing saved it
    is absent.
  - `STOCKBAR_ACCEPTANCE_CALENDAR=upcoming|past`, acceptance-only, gated like
    the others. The events fixture gains an earnings range.
- Merged: 2026-11-26 as `06689ee` (build 382.31.5).
- Benchmark: owed, under the rule for the redesign. The popover and the
  Overview gain a small list; the comparison for pull requests 158 to 162 is
  waiting for a quiet Mac and will be followed by one for this.
- Testing, on macOS 27.2.1 and Xcode 27.2: 1107 XCTest tests with 0
  failures; `checks`, `docs-check` and `build-release` pass; the worker's
  run also passed the Python helper tests and the 95 Scripts tests. 21 new
  tests (rows, pills, grouping, the grid, "Next up", requests shared with
  Income, the sidebar, time zones either side of UTC); eight temporary
  breakages were each caught and removed. Captures are in
  `build/design/shots/C2/`.
- Review: GLM 5.4 (max) found no serious defect. The lead fixed, with tests
  where they apply: "Next up" re-read its saved copies on every quote
  update (now only when the holdings, currency or day change); a holding
  added while the page is open now gets its earnings asked for; the "no
  earnings dates" footer waits for Yahoo's answer; a past day in Upcoming's
  grid opens Past at its rows; the scroll honours Reduce Motion.
- Known issues: a local portfolio with holdings was never seen on screen,
  so no earnings row, range or estimated row was seen there (the copy's
  editor would not take background typing); keyboard reach and VoiceOver
  were not tried; "today" moves on only when the page's data is reloaded,
  as on Income; "Next up" reads only the first page of a saved dividends
  answer. One of the worker's accessibility queries returned the system
  Apple menu, with one Recent Items entry; it was neither saved nor repeated.
- Verdict: retained.

### 165: Activity: kind switches that combine

- What: the owner asked, after using the Activity page on a real
  portfolio, to hide the daily interest rows, or show only them, or show
  trades and dividends together. The single **All**/**Trades**/
  **Dividends**/**Cash** switch becomes **All** plus four switches that
  combine: **Trades**, **Dividends**, **Interest** (new, taken out of Cash)
  and **Cash** (deposits, withdrawals, transfers, fees, tax and notes).
  Under All every switch is lit; a click hides or shows one kind;
  Option-click, or **Show Only** in a switch's menu, shows one kind alone;
  hiding the last kind gives All again, never an empty page. The choice is
  remembered (`activity.kinds` in defaults). The route already takes a set
  of actions, so any combination is still one request, and a full set is
  sent as All, with no action filter. Also: the user guide now lists the
  "Not set" key state added in pull request 162, and record 164's merge
  line.
- Merged: 2026-11-26 as `6539947`.
- Benchmark: none needed. A control on a page that is not drawn at launch.
- Testing, on macOS 27.2.1 and Xcode 27.2: 1109 XCTest tests with 0
  failures; `checks` and `docs-check` pass. New tests cover how the
  switches combine, the queries they send, the saved choice and the empty
  message for each kind; two temporary breakages (a full set not treated as
  All, and the choice not saved) were each caught and removed. Seen in the
  acceptance copy in dark at the default size under All; a click could not
  be sent to the copy (the screen was locked), so the other states were not
  seen on screen.
- Review: by its author.
- Known issues: none known.
- Verdict: retained.

### 166: Settings: every tab as Glass cards, at the page's full width

- What: the owner chose for Settings to run the full width of the page,
  like every other page. The five tabs that were macOS grouped forms
  (General, Menu Bar, Appearance, Refresh, Advanced) could not: macOS caps
  a grouped form's groups at about 702 points and ignores row backgrounds.
  They are rebuilt as Glass cards, as Connections already was, from one
  shared set of views in `StockbarDesign.swift`: `StockbarSettingsPage`,
  `StockbarSettingsSection` (a card with a heading, optional footer and
  hairlines between rows), `StockbarSettingsRow` (title and explanation on
  the left, the control at its natural width on the right) and
  `StockbarSettingsSwitchStyle`. Connections uses the same section view.
  The 700-point cap from pull request 162 is gone; Folync's buttons now fit
  on one row even at the minimum size. Every control, binding, label,
  order and hook is unchanged; the worker diffed the lists from the old and
  new source. Pickers draw as bordered pop-ups, macOS's standard outside a
  form. VoiceOver now reads each picker and switch by its own name, which
  the grouped form did not, and card titles are headings.
- Merged: not yet. The date and squash commit are filled in by the next
  pull request.
- Benchmark: owed, under the rule for the redesign (more cards on a page
  that is not drawn at launch).
- Testing, on macOS 27.2.1 and Xcode 27.2, on the branch rebased onto
  pull request 165: 1115 XCTest tests with 0 failures; `checks`,
  `docs-check` and `build-release` pass. The worker's run on its own base
  also passed the Python tests and the 95 Scripts tests; six new layout tests (no width cap, cards filling
  their width, controls at natural width on the right, the text field
  stretching, explanations under their titles, tab names and order) and
  seven temporary breakages, each caught and removed. 60 captures, before
  and after, every tab in dark and light at the default and minimum size,
  are in `build/design/shots/D6/`.
- Review: by the session lead against the captures and the worker's
  before/after list of controls.
- Known issues: some states were not seen in the new layout: the update
  rows (updates are off in the acceptance copy), a real last-backup date,
  the Python helper's set-up states, an exchange-rate failure, the
  external-display warning, the refresh status line and Edit Order. The
  worker could not scroll by wheel and pressed the copy's scroll-bar page
  buttons instead, and set two menu-bar pickers and typed in the template
  field inside its copy; one of its accessibility reads was not filtered
  and included the copy's own menu names.
- Verdict: retained.

## Rust evaluation, 2026-11-12

No component was moved to Rust, and none is recommended. The one place where
a rewrite would save a large amount is the Python helper, and that saving
comes from leaving Python, not from arriving at Rust: Swift reaches the same
floor with the toolchain the app already has. Whether the market data fetch
should leave Python at all is a larger question, set out at the end for the
repository owner. Nothing here has been built beyond two ten-line programs
that start and wait.

### Candidates

| Candidate | What Rust could save | Finding |
| --- | --- | --- |
| The Python helper: `stockbar_worker.py` running `get_stock_data.py` and `get_ohlc_data.py` | At most what the helper holds: 92.1 MB on real data, all of the time (pull request 86) | Measured below. A compiled helper starts from 1 to 3 MB in either language |
| Arithmetic inside the app: history thinning, risk and attribution figures | Nothing found | The app is compiled Swift. Rust would run the same arithmetic over the same data and add a C boundary with copies across it. Idle CPU is 0.082 s/min, so there is nothing to win at idle; what the 2.29 s of launch CPU is spent on is not profiled yet (planned item 9). Both figures are the "after" side of pull request 87's comparison, which is the current `experimental`. This row is reasoning, not a measurement, and is reopened if that profile finds a loop of the app's own |
| Reading and storing history | Nothing found | The cost is in Core Data and in what the app keeps of what it reads. The carried-over changes cut both in Swift. Rust cannot replace the store without replacing Core Data |

### What the helper's memory is made of

`Scripts/perf/helper_layers.py` against the helper's own interpreter (Python
3.13, yfinance 1.8.0), five starts a row, 10:33 UTC, nothing fetched:

| Process | Memory held: median (range) of 5 starts | CPU to ready | Time to ready |
| --- | --- | --- | --- |
| Interpreter only | 6.5 (6.5 to 6.6) MB | 0.01 (0.01 to 0.02) s | 0.01 (0.01 to 0.04) s |
| + the standard library modules the helper uses | 12.1 (11.9 to 12.1) MB | 0.03 (0.03 to 0.03) s | 0.03 (0.03 to 0.05) s |
| + requests | 20.4 (20.4 to 20.4) MB | 0.06 (0.06 to 0.07) s | 0.07 (0.06 to 0.09) s |
| + pandas | 57.2 (57.1 to 57.4) MB | 0.22 (0.21 to 0.25) s | 0.22 (0.21 to 0.36) s |
| + yfinance: everything the helper imports | 70.6 (70.5 to 70.6) MB | 0.29 (0.29 to 0.30) s | 0.29 (0.29 to 0.34) s |
| Compiled Swift program with a URLSession and a JSON decoder ready | 2.4 (2.4 to 2.5) MB | 0.01 (0.01 to 0.01) s | 0.01 (0.01 to 0.18) s |
| Compiled Rust program, standard library only | 1.2 (1.2 to 1.2) MB | 0.00 (0.00 to 0.00) s | 0.00 (0.00 to 0.15) s |

- pandas accounts for 36.8 MB and yfinance for a further 13.4 MB: 50.2 MB of
  the 70.6 MB. The helper uses pandas only through the tables yfinance
  returns.
- After real fetches the helper holds more than it does straight after its
  imports: 92.1 MB in the sample of the installed app.
- The Rust program has no HTTP client, so a real Rust helper holds more than
  1.2 MB. That is not measured: it needs third-party crates, which were not
  downloaded. Neither floor has fetched anything.

### Why not Rust for the helper

- The two floors are 1.2 MB apart. Leaving Python saves 68 MB or more in
  either language.
- Swift code can do the fetch inside the app with `URLSession`, as the app
  already does for exchange rates, Folync and Trading 212. There is then no
  helper process, no 0.29 s of CPU to start one, and no second executable to
  sign. Rust would be a second process, or a library behind a C bridge with
  its own networking runtime inside the app.
- Rust adds a second toolchain to every build. `rustc` 1.99.1 is installed on
  this Mac through `rustup` but is not on the `PATH`; the GitHub workflows
  would need it as well, and the release workflow is outside what this branch
  may change. It also adds third-party crates to keep current.
- One point does favour Rust. Yahoo has no official interface, and maintained
  Yahoo clients exist as crates: `yfinance-rs`, which describes itself as a
  port of the Python library (0.9.1 on docs.rs), and `yahoo_finance_api`
  (4.1.0, with cookie and crumb handling in its source). For Swift a search
  found one package, SwiftYFinance, last released in March 2025. This comes
  from a web search on 2026-11-12. Neither crate was built or run, and how
  quickly they follow Yahoo's changes was not checked.

### The larger question: should the fetch leave Python?

What it would bring, on real data. The "now" figures are measured (pull
request 86); the rest is expected, not measured.

- Memory: the app and helper together hold 175.1 MB on average now, 92.1 MB
  of it the helper. Pull request 86's switch, turned on, brings that to
  about 114 MB. With no helper it is about 83 MB plus whatever the fetch
  adds to the app.
- No Python environment: 123 MB in 5,013 files under Application Support
  today, with its set-up step, its missing-package alert and its own security
  updates.
- About 890 lines of Swift that exist to run Python (`PythonWorkerPool`,
  `PythonProcessRunner`, `PythonEnvironmentSetup`) would go.

What it would cost.

- 1,712 lines in `get_stock_data.py` and 213 in `get_ohlc_data.py`, with 759
  lines of tests, rewritten and shown to give the same answers. Twelve Data
  and Financial Modeling Prep are documented JSON interfaces and carry little
  risk.
- Yahoo is the risk. The helper asks yfinance for daily and intraday history,
  and for the market state and the pre-market and after-hours prices, which
  come from an endpoint that wants a session cookie and a token. yfinance
  1.8.0 requires `curl_cffi`, a library for making requests with a browser's
  network fingerprint. A native client takes that upkeep over from yfinance's
  maintainers. Whether Yahoo accepts `URLSession` as it is can only be found
  out against the live service.
- The tests here must not contact live providers, so equivalence needs
  recorded responses plus a supervised comparison against the live services.

The options:

| | Option | Memory, app and helper | Risk |
| --- | --- | --- | --- |
| A | Keep Python and turn on pull request 86's switch | about 114 MB on average (expected) | Smallest: a switch that is off unless turned on |
| B | Fetch in Swift, with the Python helper kept as the fallback when a native fetch fails | about 83 MB while the native fetch works (expected) | Two implementations to keep until the native one has earned trust |
| C | Fetch in Swift and remove Python | about 83 MB (expected) | Largest: no fallback if Yahoo turns the native client away |
| D | A Rust helper on `yfinance-rs` | a few MB more than C (not measured) | Yahoo upkeep shared with the crate's one maintainer; the build and release costs above |

Recommended: A now. Then B in stages if the remaining 30 MB or so and the
end of the Python set-up are wanted, starting with a supervised trial of a
Swift fetch against Yahoo, since that settles whether C is reachable or D is
the candidate. B, C and D change where every price comes from, so none of
them starts without the repository owner's decision. Asked again on
2026-11-12, the answer given was the same: A, not Rust, and B only after a
supervised trial against Yahoo.

## Tried and rejected

| Idea | When | What was measured | Why dropped |
| --- | --- | --- | --- |
| Hand freed launch memory back to the system with `malloc_zone_pressure_relief` after the launch load | 2026-11-11, before the transition | It released 0 bytes in all 11 calls, and idle footprint stayed inside its usual spread | The allocator does not return those pages on request. Idle footprint comes down by lowering what the launch allocates, not by asking afterwards. Never committed |
| Move a component to Rust | 2026-11-12, pull request 88 | A compiled helper starts from 1.2 MB in Rust (standard library only) and 2.4 MB in Swift (with `URLSession` ready), against 70.6 MB for the Python helper after its imports | The saving comes from leaving Python, and Swift reaches it with the app's own toolchain and without a helper process. Nothing inside the app was found that Rust would make faster or smaller. See [Rust evaluation](#rust-evaluation-2026-11-12) |
| Precompiled bytecode for the Python helper's own scripts | 2026-11-12, plan item 8 | Compiling all three scripts takes 8.2 ms of a 330 ms helper start | About 2 percent of the start, for a build step and files to keep in step with the scripts. Never written |
| Thin only the newly aged part of each price series after a recorded snapshot | 2026-11-12, plan item 11 | A full pass costs 32.6 ms on the main actor for each recorded snapshot at the fixture's size, 0.0065 s/min at the default interval | The saving is about 2 s of CPU in a trading day, and it needs remembered state that every place replacing a series must keep true. Never written |
| Draw the main window's chart as one area plot and one line plot in place of a mark for every point | 2026-11-12, milestone 1 | Three launches of each build: Swift Charts' classes among the 27 largest fell from 5.02 MB to 4.38 MB (2.75 MB in one launch), and the untyped allocations it was meant to lower did not move (19.7 to 20.4 MB before, 20.2 to 20.6 MB after) | About 0.6 MB, for a change to how the chart is built that could be tried on one macOS version only. Appearance and VoiceOver were not compared. Never committed |
| Take the rolling-digit transition out of the main window's figures | 2026-11-12, milestone 1 | One launch of each build with allocations named: 6.52 MB of cached glyph bitmaps with the transition and 0.46 MB without | It removes an animation that is there on purpose, to empty a cache the system owns, and in normal use the app starts without a window (corrected on 2026-11-13: it shows the window at every launch). Six lines if the owner wants the memory more than the animation. Never committed. The owner asked for a switch in its place, which is pull request 98 |
| Combine a refresh's three Core Data transactions, or stop recording Core Data's change history (finding 7) | 2026-11-13, [Findings 6 and 7 looked into](#findings-6-and-7-looked-into-2026-11-13) | `sample` over four refresh passes: 17 busy samples on Core Data's threads of 3,234 in all, under 10 ms a pass. Each pass makes three write transactions and writes 35 change-history rows | A few milliseconds a refresh, too little to measure against the rest. The change history is part of how the store is opened, so turning it off risks the store opening read-only. Left as it is at the owner's choice. Never written |

## How this branch works

- Since 2026-11-17, at the owner's word, `experimental` is used only for
  major changes, such as the overhaul this log records, or for temporary
  testing. Ordinary changes go straight to `testing`. When it is not in
  use, it is brought up to the latest release and left there. While it is
  in use, this log changes only through pull requests into
  `experimental`. When a use ends, its last record goes in with the
  release pull request into `testing` that ships the work, as for 3.8.0;
  that pull request is the one exception.
- `experimental` was created from `testing`. Nothing reaches `testing` or
  `main` from here without an explicit instruction; no releases, no changes to
  repository settings, no force-pushes or history rewrites. Since pull request
  97 was merged, at the owner's word, each push to `experimental` is
  published as an experimental build: a prerelease, offered only to people
  who chose the Experimental update channel.
- One optimisation is one branch (`perf/*`, `feature/*`, `refactor/*`,
  `rust/*`) from the latest `experimental`, one pull request, and one squash
  commit, so it can be read and reverted alone. A merged change is undone with
  `git revert` through a pull request.
- Every pull request carries its own before/after table from
  `bash Scripts/perf/compare.sh <before> <after>`, measured for that pull
  request. A row counts as "lower" or "higher" below p = 0.01. Between 0.01
  and 0.05 it is "possibly" and needs a repeat. Anything else is "no
  measurable change". Each pull request names the rows it is meant to move.
  A row that moves without having been named is repeated before it counts,
  whatever its p value: pull request 95 had three such rows across two runs,
  for code the benchmark never runs. Nothing else is started on the Mac
  while a comparison runs, a subagent that only reads files included: pull
  request 86's first run had one beside it, marked two memory rows, and was
  repeated.
- Merge bar: the app builds cleanly, no new test failures, the affected
  behaviour still works, the benchmark record is complete, no known
  regression. A change that trades one metric for another stays open for a
  decision. A performance change with no measurable benefit is not merged.
- From 2026-11-20, at the owner's word, the benchmarks are parked while
  another project's builds and tests run on the same Mac: no comparison is
  started until that work has been idle for more than 20 minutes. Until
  then the redesign's pull requests are merged on their local checks and
  review, each record saying that its benchmark is owed. One comparison is
  run for each phase of the redesign, in the first quiet window after the
  phase's last pull request is merged. It runs from the last commit
  measured to the newest, so it also covers pull requests of other phases
  merged in between, and its table goes into this log through the next
  pull request. A
  row that moves is repeated, and if it holds, the phase's pull requests
  are measured one by one to find the cause. This replaces, for the
  redesign, the rule that every pull request carries its own table.
- The CI workflow does not run for `experimental` or for pull requests into
  it, so every check is run locally: `bash script/develop.sh test`, `checks`,
  `python-tests`, `build-release`, and
  `python3 -B -m unittest discover -s Scripts/tests -p 'test_*.py'`. From
  pull request 97 on, the release workflow does run for a push to
  `experimental`. It builds and publishes the newest commit and runs none of
  the tests.
- Checkpoint tags are named `experimental-checkpoint-<date>-<name>`. The
  release workflow reacts to `vX.Y.Z` tags and reads tags of the form
  `testing-<build>` and `experimental-<build>`, where the build starts with a
  digit. A checkpoint tag is none of these.
- The merge date and squash commit of a pull request are filled in by the next
  pull request, since they do not exist until after the merge.
- A promotion to `testing` is made only at the owner's word, as a pull
  request from a temporary branch at the commit to promote. It is never
  made from `experimental` itself: GitHub deletes a merged pull request's
  branch, and `experimental` is not protected from deletion. It is merged
  with a merge commit. Straight afterwards `testing` is merged back into
  `experimental` through a pull request, again with a merge commit, the one
  exception to the squash rule above: until then experimental builds are
  numbered below the new testing build.

## The transition, 2026-11-11

- `experimental` was created from `origin/testing` at `47c1bda` and pushed.
  That commit has the same files as `origin/main` (`75be612`), which is one
  merge commit ahead.
- `origin/main` was `75be6125b0f0` and `origin/testing` `47c1bdac9159` before
  and after.
- The earlier work was eight unpushed commits on a local branch based on
  `75be612`. It was moved, file for file, onto branches from `experimental`:
  `perf/benchmark-baseline` (pull request 84), `perf/helper-idle-exit`,
  `perf/release-without-coverage`, `perf/batched-history-read`,
  `perf/chart-values-read` (stacked on the batched read: both edit the same
  file and test class) and `perf/fitted-price-arrays`. The earlier log,
  `Docs/perf_2026-11-11.md`, is replaced by this file and was not carried over.
- Automation: the CI workflow runs for `main` and `testing` only; the release
  workflow for pushes to `testing`, `release-test/**` branches and `vX.Y.Z`
  tags; the Python lock update on a Monday schedule. None ran for any push
  made here. One ruleset blocks deletion and force-pushes on `main` and
  `testing`. GitHub deletes a merged pull request's branch itself.

## Before the transition

Earlier the same day the carried-over changes were measured together, against
`75be612`, with an earlier version of the benchmark. Those figures are not
repeated here: each change is measured again in its own pull request. Three
findings from that work shape the plan and are not visible in the isolated
benchmark:

- On real data the Python helper was running all of the time with the 15
  minute idle timeout and about a third of the time with 90 seconds, at the
  default five minute refresh. The helper holds about as much memory as the
  app.
- The idle footprint in the benchmark is bimodal on the baseline (roughly 100
  or 130 MB from launch to launch), because the allocator keeps or returns
  freed launch memory. The allocated-heap figure is the steadier one.
- The launch peak in the benchmark is mostly graphics memory for the first
  window, not the history load. On real data, where no window opens at launch,
  the history load is the peak.

Unrelated problems noticed and left alone: `MemoryManagementService` compares
resident size, not footprint, with its thresholds; `PythonWorker.stop()` sends
SIGTERM straight after closing stdin; acceptance and benchmark runs leave
`com.stockbar.acceptance` entries in `~/Library`; acceptance mode logs the
missing helper as an error; the popover chart reloads several times during
launch.

## Who did what

| Work | Model | How it went |
| --- | --- | --- |
| Transition, benchmark tooling, baseline, this log | Fable (orchestrator) | Done directly: git work and measuring, nothing to hand off |
| Before the transition: independent reviews of the helper change and of the history-read changes | Opus | Worth it both times. No defects; each found a real gap in the tests, since closed |
| Pull request 85 | Fable (orchestrator) | Done directly: a one-line scheme change, reviewed by reading the diff and inspecting the two builds |
| Pull request 87 | Fable (orchestrator) | Re-measured and re-read directly. The change itself was reviewed by Opus before the transition |
| Pull request 88, the Rust evaluation | Fable (orchestrator) | Done directly: measuring, two web searches and the write-up |
| Pull request 89 | Fable (orchestrator), with two independent reviews by Opus | Worth it. The first review found a real defect: a slow launch read could undo the UK price scale repair for the session. It was fixed, with tests, before the comparison. The second review, of the fix, found no defect and pointed out a behaviour change the description had missed |
| Pull request 90 | Fable (orchestrator), with one independent review by Opus | Worth it. The change was written before the transition. The review read the branch after `experimental` was merged into it and caught that the tests no longer compiled, before a build had been spent finding out |
| Pull request 91 | Fable (orchestrator) | Done directly: a dozen lines of shell and one test |
| Pull request 92 | Fable (orchestrator) | Done directly. The change was written before the transition; it was re-read, trimmed of the code it replaces and corrected after its first measurement |
| Pull request 93 | Fable (orchestrator) | Done directly. The carried-over change was nine lines; reading the append path before measuring showed it would undo itself in use, and the step growth and two tests were added |
| Pull request 94 | Fable (orchestrator) | Done directly: nine lines of shell, two tests and two sentences of documentation, tried by hand on a build with the counters and one without. It waited a day for the owner's decision and was merged on their word |
| Pull request 95 | Fable (orchestrator) | Done directly: found from the owner's screenshot and the drawing code, then checked by drawing the app's own chart view with the old formula and the new. A probe build showed the benchmark never draws that chart, which settled three rows the benchmark had marked |
| Milestone 1: the comparison, the soaks, the launch with allocations named and the two trial builds | Fable (orchestrator) | Done directly. Each step was a measurement to read before choosing the next, with nothing independent to hand to a subagent |
| Pull request 97, the Experimental update channel | Fable (orchestrator), with a check of the Settings window by Sonnet and one independent review by Opus | Sonnet was used at the owner's instruction for driving the screen: it worked through the trial copy's Settings window and reported what each channel was offered, in 53 tool calls and about 138,000 tokens. The Opus review was worth it: it found that a release would never have reached the channel and that the tests and notes had Sparkle's ordering wrong, in 62 tool calls, about 250,000 tokens and fifteen minutes |
| Pull request 86 reworked as a switch | Fable (orchestrator), with two checks of the Settings window by Sonnet and one independent review by Opus | Sonnet drove the screen at the owner's instruction: the first check read and toggled the switch in 23 tool calls and about 128,000 tokens but could not scroll the page; the second settled that it scrolls, through the scroll bar's accessibility buttons, in 15 tool calls and about 128,000 tokens. The Opus review was worth it: no defect in the pool, but it found that the switch's description promised the helper is kept in cases where it is not, and that two tests could not fail, in 23 tool calls, about 155,000 tokens and six minutes. My own reading before it found the one race that was fixed |
| Pull request 98, the switch for the rolling digits | Fable (orchestrator), with one check of the Settings window by Sonnet and one independent review by Opus | Sonnet drove the screen at the owner's instruction: it read both Memory switches word for word, turned the new one off and looked at the Overview page, in 24 tool calls, about 126,000 tokens and 80 seconds. The Opus review found no defect and was still worth it: the description and the guide stated more than had been measured, the test did not read what a figure does, and nothing kept later figures on the modifier, in 55 tool calls, about 201,000 tokens and eleven minutes. It ran beside pull request 86's first comparison, which had to be repeated on a quiet Mac |
| The promotion to `testing` and pull request 101 | Fable (orchestrator) | Done directly: two pull requests, the checks on the published build and one comparison. Reading the repository's settings before merging showed that pull request 99 would have deleted `experimental`; it was replaced before anything was merged |
| Pull request 102, the helper's switch on by default | Opus 5.5 (orchestrator, from here on at the owner's choice of model), with one check of the Settings window by Sonnet | Done directly: a five-file change and its test. Sonnet read the switch in the trial copy in 16 tool calls, about 105,000 tokens and 51 seconds; the copy's window is the main window, with Settings in its sidebar, and making it taller was enough to reach the Memory section. No independent review: a change of default, whose test was read against the diff |
| The Dependabot alerts and pull request 103 | Opus 5.5 (orchestrator) | Done directly. The alerts' history and GitHub's dependency graph showed the code had been fixed for eight days; the alerts were dismissed through the API with a note, and the comment change was checked against the lock and the launch-time check |
| The review of the refresh path | Opus 5.5 (orchestrator), with one read-only review by Opus | Worth it. The reviewer had not seen the code and read the refresh path end to end in 26 tool calls, about 287,000 tokens and five and a half minutes, after a first attempt failed on a server error. Three of its claims were checked again in the code before they went to the owner, and held |
| Pull request 104 | Opus 5.5 (orchestrator) | Done directly: one function pair replaced and three tests, measured with a script that runs the helper's `main()` offline |
| Pull request 105 | Opus 5.5 (orchestrator) | Done directly: the seam the review had pointed to, the benchmark's extra window and its report rows, tried with one launch before the comparison |
| Findings 6 and 7 looked into | Opus 5.5 (orchestrator) | Done directly: a profile, an SQL log and a trial copy with counters, each read before choosing the next; nothing independent to hand off |
| Pull request 106 | Opus 5.5 (orchestrator), with one independent review by Opus | Done directly: one loop reordered and moved into two functions, a test shown to fail on the old code, and the trial copy's counters run again on the change. The review, read-only while the comparison ran, found no defect and was worth it: a comment gave the wrong reason for looking holdings up by name, the log lines moved more than the description said, and a suspension notice can now lag in one rare case. 24 tool calls, about 153,000 tokens and four and a half minutes |
| Pull request 107 | Opus 5.5 (orchestrator) for the first code commit, then Fable 5.2 (orchestrator again, at the owner's change of model) for the review fixes, the timing and the comparison, with one independent review by Opus | Done directly: one function given a window, its two callers' paths and three tests, timed in the trial copy before and after. The review, read-only, found no defect and was worth it: it showed the first test would have passed with a margin too small to be safe, that a miss left a stale series counted in the cache, and that two comments overstated what they described. 18 tool calls, about 133,000 tokens and four and a half minutes |
| Pull request 108 | Fable 5.2 (orchestrator), with one independent review by Opus in two passes | Done directly: one class and three tests, with the cache's file writes counted in the trial copy before and after. The review, read-only, was worth it: it found no defect in the comparison or the locking, but showed that the first version no longer wrote again a file deleted from outside the app, which the second code commit puts right, and corrected two comments. It also said key order does not vary between encodings of one dictionary; a measurement showed it does, and the reviewer withdrew that. First pass 33 tool calls, about 158,000 tokens and seven minutes; the second look at the reworked code 3 tool calls and a minute and a half |
| Pull requests 109 and 110 | Fable 5.2 (orchestrator), with one independent review of both by Opus | Done directly: four lines and seven, the popover's redraws counted in a trial copy and the snapshot list sized with a standalone program. The review, read-only while the shared comparison ran, took 32 tool calls, about 146,000 tokens and six minutes. It found no defect and was worth it: it checked every reader of the session's snapshot list and every way the popover closes, and named the one thing the code could not show, when AppKit reports a close, which led to the guard in pull request 109 and a standalone check of it |
| The full comparison of pull requests 109 and 110, the dropped separate comparisons, the trial's third run and pull request 112 | Fable 5.2 (orchestrator) for the measuring on 2026-11-16, then Opus 5.5 (orchestrator, at the owner's change of model) for this record | Done directly: unattended runs with readings taken beside them and set-aside rules fixed before any figure existed. Two of the three comparisons were set aside under those rules, and a rule that sent one "possibly" row to two more comparisons cost about four hours before the owner stopped it. Next time the owner should get that choice before the extra runs start |
| The second promotion to `testing` and pull request 114 | Opus 5.5 (orchestrator) | Done directly: the tests on the promoted commit, two pull requests and the checks on the published build |
| The redesign's groundwork, pull requests 135 and 136 | Fable 5.2 (session lead) for the specifications, the review and the records; one Opus 5.5 worker for each pull request's code, in its own worktree | Worth it. The lead's reading found faults in both before they were merged: in 135 the fetch policy never dropped kept pages, a queued request still ran after its callers had gone, and a day given as a date could shift by a day; in 136 the helper read Yahoo's dates in the Mac's time zone and asked again for symbols Yahoo does not know. Each was fixed with a test. The workers' tool calls and tokens were not recorded |
| The Glass redesign, pull requests 137 to 140 | The same arrangement: one worker for the surfaces, then three in parallel for the popover, the Overview and the shell | Worth it for the building. Merging three branches written at the same time cost the lead a round of conflicts for each, and the popover could not be opened in the acceptance copy until the lead added a launch option. One worker clicked twice outside its own window; the owner was told, and the specifications since require a click to be measured against a capture of the same window |
| The Folync pages, pull requests 141 to 143 | One worker for the stand-in server's ledger routes, then three in parallel for Activity, Trades and Income | Worth it for the building, with the same cost on merging: all three added a sidebar section, so six files conflicted twice. Later batches add at most one section each. The lead added the Partial position to Trades, removed a guessed currency from Income, and replaced timed waits in three tests with conditions the tests control |
| The second batch, pull requests 144 to 147: Allocation, the Settings switches, Holdings and Risk | Fable 5.2 (session lead) for the specifications, the review, the merges and the records; four Opus 5.5 workers in parallel, each in its own worktree | Worth it for the building. During 145 the lead traced why the acceptance copy could not change a setting seeded before it started: its defaults suite is named by a path, and on macOS 27.2.1 a process never reads back its own change to a key already in such a file. That became pull request 148. In 146 the lead restored the editing table's column widths, which the worker had narrowed without seeing them, and in 147 corrected "trading days" to "days" for the worst fall's length, which is counted in calendar days. Neither the filled Risk page nor Allocation's grid of correlations was seen in the running acceptance copy, only in drawings made off screen, and the owner was asked to look at both in the real build |
| Pull requests 148 to 150: the acceptance copy's seeded settings, the Charts and Data Health tidy, and the Holdings editing table | Fable 5.2 (session lead), with three Opus 5.5 workers, each in its own worktree | Worth it, with one cut-off. During pull request 150 the Mac's disk filled to 119 MB free with this work's own leftovers: the build folder every acceptance launch left in the temporary directory, and the build caches of every worktree. It stopped the D1b worker part-way through showing its tests fail. The lead removed about 45 GB of those leftovers, keeping the logs, captures and benchmark results, removed the breakage left in the worker's tree, and finished the breakages and checks. Two workers' accessibility reads returned the system's Apple menu, Recent Items included; neither saved or repeated it, and the owner was told. The D4 worker scrolled once without a capture id of the same window. Later specifications are to say: read a window's tree with a query and never the menu bar, give no pointer or scroll input without a capture of the same window, and clear build folders after each batch |
| The redesign's comparison, run twice on 2026-11-20, and pull request 151 | Fable 5.2 (orchestrator) for both comparisons; then Gemini 4 Neon (orchestrator, at the owner's change of model), which handed this record and the comparison of pull request 140 to Claude Opus 5.5 | Done directly for the measuring: unattended runs, each after twenty quiet minutes, with the set-aside rules fixed before any figure existed. A first attempt was cut off by a restart of T3 Code before it measured anything. This record was written by Opus 5.5 from the two reports and the chain logs and checked against them; its tool calls and tokens were not recorded |
| The Yahoo check and pull request 153 | Claude Opus 5.5 (session lead) | Done directly: one supervised live run of twelve public symbols, which found that the events lookup had never answered, then the one-line fix in each helper, the tests and this record. Worth doing before Calendar was built: built first, it would have shown no dates for any holding and looked like missing data. |
| Pull request 154, Allocation's Cash row | Claude Opus 5.5 (session lead) for the specification, the review and the record; one Opus 5.5 worker in its own worktree | Worth it: thirteen tests, six breakages and before-and-after captures of every view. The lead checked the cash source against the net value's and the captures. The worker's accessibility reads twice returned its copy's menu bar, against the new rule, and its copy became the active app once. |
| Pull request 155, the Cash row's fixes | Claude Opus 5.5 (session lead); GPT-6.2 Astra (extra high) and Gemini 4 Neon as independent reviewers, at the owner's suggestion; two Opus 5.5 workers in turn | Worth it. The two reviews of 153 and 154, made without each other, agreed on every main fault and found what the lead's reading had missed: another account's cash, a built-in exchange rate, and a Python bug that divided a pound price by 100. Astra's second review found five more in the first fix. Reviews cost little next to the workers, and are worth asking for on any change that works out money figures. |
| Pull request 156, Trading 212 cash-only accounts | Claude Opus 5.5 (session lead); GLM 5.4 (max) and Gemini 4 Neon as independent reviewers; two Opus 5.5 workers in turn | Worth it again. Asked for one small sync fix, the reviews found five faults around switching accounts that predate it and affected linked accounts too. Asking all three advisors what to do next also helped: they agreed on the order, and GLM's point about holdings beside the account shaped the fix. |
| Pull request 157, the card highlight's memory | Claude Opus 5.5 (session lead); one Opus 5.5 worker for the trace and the fix | Worth it: one launch per variant, which needs no quiet Mac, found a single cause in about two hours, where timed comparisons had twice been crowded out by another project's builds. Neon's suspect, the shadow, was cleared by the first variants. |
| Pull request 158, the local Income estimate, and the comparison for 152 to 157 | Claude Opus 5.5 (session lead) for the specification, the comparison, two fixes and the record; one Opus 5.5 worker; GLM 5.4 (max) as reviewer | Worth it. GLM found no bug and two small faults in the figures, which the lead fixed directly rather than through another worker. Running the comparison when the Mac was quiet that evening, at the owner's request, gave both runs in under two hours. |
| The third promotion to `testing` and pull requests 160 and 161 | Claude Opus 5.5 (session lead) | Done directly: a one-line test fix that CI found, the promotion, the checks on the published build and this record. The bring-back into `experimental` came a day late |
| Pull request 162, Settings and Alerts as mocked | Claude Opus 5.5 (session lead) for the specification, review, one fix and the record; one Opus 5.5 worker | Worth it. The worker could not click (the screen was locked) and built an uncommitted aid to reach each tab, which it disclosed; up to ten of its copies ran at once, and each launch left an acceptance-only Keychain item |
| Pull request 163, the Sortino reading | Claude Opus 5.5 (session lead) | Done directly: a few lines of text and their tests |
| Pull request 164, Calendar and "Next up" | Claude Opus 5.5 (session lead) for the specification, review, four fixes and the record; one Opus 5.5 worker; GLM 5.4 (max) as reviewer | Worth it. The worker could not type in its copy (the screen was locked), so the local portfolio's Calendar with holdings was never seen; one accessibility query returned the system menu |
| Pull request 165, Activity's kind switches | Claude Opus 5.5 (session lead) | Done directly, at the owner's request after using the page |
| Pull request 166, Settings as cards | Claude Opus 5.5 (session lead) for the specification, review and the record; one Opus 5.5 worker | Worth it: forty minutes, with a before/after list of every control. It pressed scroll-bar buttons and set two pickers in its own copy, which it disclosed |

Haiku has not been used, and Sonnet only to drive the screen, for pull
requests 97, 86, 98 and 102: nothing else so far has been parallel or self-contained
enough to repay a cold start, and most of the elapsed time is benchmark
runs, which no model speeds up.
