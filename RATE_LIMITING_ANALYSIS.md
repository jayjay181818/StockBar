# Rate Limiting Analysis - UNH Update Issue

**Date:** 2025-10-01
**Issue:** UNH (and potentially other stocks) not updating for 35+ minutes
**Root Cause:** Yahoo Finance API rate limiting

---

## Investigation Summary

### Diagnostic Test Results

Ran diagnostic script (`test_unh_refresh.py`) to test Python backend directly:

```
❌ Individual UNH fetch: FAIL
❌ Batch fetch test:     FAIL
❌ Rate limiting check:  FAIL

Error: Too Many Requests. Rate limited. Try after a while. (YFRateLimitError)
```

### Root Cause Identified

**Yahoo Finance is rate limiting API requests.** The app's current refresh strategy is triggering too many requests to Yahoo Finance, causing the API to block further requests temporarily.

---

## Current Refresh Configuration

### Refresh Intervals (from code analysis)

1. **Cache Interval:** 15 minutes (900s) - `CacheCoordinator.swift:13`
2. **Refresh Timer:** 5 minutes (300s default) - `RefreshService.swift:30`
3. **Staggered Refresh:** Individual stocks refreshed every 5 minutes
4. **Batch Refresh:** All stocks refreshed when cache expires (15 min)

### Why Rate Limiting is Occurring

**Scenario with large portfolio (10+ stocks):**

- **Batch refresh:** Every 15 minutes, fetches ALL symbols (1 batch request)
- **Staggered refresh:** Every 5 minutes, fetches 1 symbol individually
- **Total requests per hour:**
  - 4 batch requests × 10 symbols = 40 symbol fetches
  - 12 individual refreshes = 12 symbol fetches
  - **Total: ~52 requests/hour per symbol**

**Yahoo Finance free tier limits:** ~2,000 requests/hour total (estimated)

**With 10 stocks:** 52 × 10 = 520 requests/hour (acceptable)
**With 20+ stocks:** 52 × 20 = 1,040 requests/hour (risky)
**With 50+ stocks:** 52 × 50 = 2,600 requests/hour (**RATE LIMITED** ❌)

---

## Current Mitigation in Place

### Exponential Backoff (Already Implemented ✅)

From `CacheCoordinator.swift:17`:
```swift
private let retryIntervals: [TimeInterval] = [60, 120, 300, 600]  // 1min, 2min, 5min, 10min
```

**Progressive delays when failures occur:**
- 1st failure: retry in 1 minute
- 2nd failure: retry in 2 minutes
- 3rd failure: retry in 5 minutes
- 4th+ failure: retry in 10 minutes

### Circuit Breaker (Already Implemented ✅)

From `CacheCoordinator.swift:20-21`:
```swift
private let circuitBreakerThreshold = 5  // Consecutive failures before suspension
private let circuitBreakerTimeout: TimeInterval = 3600  // 1 hour suspension
```

**After 5 consecutive failures:**
- Symbol is suspended for 1 hour
- No refresh attempts during suspension
- Manual retry available via UI

### Cache Coordination (Already Implemented ✅)

From `CacheCoordinator.swift:13-14`:
```swift
let cacheInterval: TimeInterval = 900  // 15 minutes for successful fetches
private let maxCacheAge: TimeInterval = 3600  // 1 hour before forcing refresh
```

**Cache logic:**
- Fresh (< 15 min): No refresh needed
- Stale (15-60 min): Refresh on next check
- Expired (> 60 min): Force refresh

---

## Why UNH Specifically is Stuck

### Likely Scenario

1. **Rate limit hit** - Yahoo Finance returns "Too Many Requests"
2. **All stocks marked as failed** - Including UNH
3. **Exponential backoff activated** - UNH moved to 10-minute retry interval
4. **After 5 failures** - UNH suspended for 1 hour via circuit breaker
5. **Displays old data** - Last successful fetch timestamp retained
6. **No visible error** - Error message may not be displayed prominently

### Current State of UNH (Hypothesis)

Based on the 35+ minute stale data:
- **Cache Status:** Likely `.suspended(failures: 5+, resumeIn: XXm)`
- **Last Successful Fetch:** 35+ minutes ago (before rate limit hit)
- **Last Failed Fetch:** Multiple attempts in last 10-30 minutes
- **Consecutive Failures:** 5+ (triggered circuit breaker)
- **Current State:** Suspended, waiting for 1-hour timeout to expire

---

## Immediate Solutions

### Solution 1: Check Cache Inspector (Debug Tab)

**Steps:**
1. Open Stockbar preferences (⌘,)
2. Navigate to "Debug" tab
3. Scroll to "Cache Inspector" section
4. Look for UNH in the list

**What to check:**
- UNH status: Fresh/Stale/Expired/Suspended?
- If suspended: Shows "⚠️ Suspended (failed 5x, resume in XXm)"
- If suspended: "Retry Now" button should be visible

**Action:**
- Click "Retry Now" button next to UNH
- This clears the suspension and attempts immediate refresh

### Solution 2: Clear All Caches (Debug Tab)

**Steps:**
1. In Debug tab, locate "Cache Inspector" section
2. Click "Clear All Caches" button
3. Wait for refresh cycle to trigger
4. Check if stocks update (may take 5-15 minutes)

**Warning:** This resets all cache state, forcing immediate refresh of ALL stocks. May trigger rate limiting again if done repeatedly.

### Solution 3: Increase Refresh Interval (Reduce API Calls)

**Current Implementation:**
The refresh interval is configurable but not exposed in UI. Default is 5 minutes.

**Temporary workaround:**
1. Quit Stockbar
2. Run this command to increase interval to 10 minutes:
   ```bash
   defaults write com.fhl43211.Stockbar refreshInterval 600
   ```
3. Restart Stockbar
4. This reduces API calls by 50%

**To revert to 5 minutes:**
```bash
defaults write com.fhl43211.Stockbar refreshInterval 300
```

---

## Long-Term Solutions (Recommendations)

### Option 1: Adaptive Rate Limiting ⭐ RECOMMENDED

**Implementation:**
- Monitor rate limit errors across all symbols
- When rate limit detected, automatically:
  - Increase refresh interval (5min → 10min → 15min)
  - Suspend all non-critical symbols temporarily
  - Prioritize user's watchlist/favorite stocks
- Resume normal interval after cooldown period

**Benefits:**
- Automatic adaptation to API limits
- No user intervention required
- Maintains data freshness for important stocks

**Effort:** 2-3 hours (Medium complexity)

### Option 2: Refresh Interval Configuration UI

**Implementation:**
- Add picker in Debug/Advanced tab
- Options: 5min, 10min, 15min, 30min, 60min
- Update `RefreshService.refreshInterval` dynamically
- Show estimated API usage per hour

**Benefits:**
- User control over refresh frequency
- Users with large portfolios can reduce load
- Transparency about API usage

**Effort:** 1 hour (Low complexity)

### Option 3: Smart Refresh Strategy

**Implementation:**
- **Market hours:** Refresh every 5 minutes (high priority)
- **Pre/post market:** Refresh every 15 minutes
- **Market closed:** Refresh every 1 hour or on-demand only
- **Weekends:** Refresh every 4 hours or manual only

**Benefits:**
- Significantly reduces API calls during off-hours
- Focuses resources when market is active
- Natural rate limiting based on market activity

**Effort:** 3-4 hours (Medium complexity)

### Option 4: Tiered Symbol Priority

**Implementation:**
- **Tier 1 (Watchlist):** Refresh every 5 minutes
- **Tier 2 (Active positions):** Refresh every 10 minutes
- **Tier 3 (Large positions):** Refresh every 15 minutes
- **Tier 4 (Small positions):** Refresh every 30 minutes

**Benefits:**
- Most important stocks update frequently
- Reduces total API calls significantly
- User can manually trigger refresh for specific stocks

**Effort:** 4-5 hours (Higher complexity)

---

## Testing Checklist (from PROGRESS.md)

### Already Tested ✅
- [x] Rate limit detection working (diagnostic script confirms)
- [x] Exponential backoff implemented
- [x] Circuit breaker implemented
- [x] Cache coordinator logic verified

### To Verify Now 🔍
- [ ] Open Debug tab and check Cache Inspector for UNH status
- [ ] Verify "Retry Now" button appears for suspended symbols
- [ ] Test "Clear All Caches" functionality
- [ ] Confirm error messages display in stock dropdown menus
- [ ] Check if circuit breaker suspension info shows in UI

### Post-Fix Testing 🧪
- [ ] Verify UNH updates after manual retry
- [ ] Monitor for rate limiting recurrence
- [ ] Check all stocks update within expected intervals
- [ ] Verify no excessive API calls in logs
- [ ] Confirm cache status transitions correctly (fresh→stale→expired)

---

## Immediate Action Items

### For User (NOW)
1. **Open Stockbar Debug tab**
2. **Check Cache Inspector** - Look for UNH and other suspended symbols
3. **Click "Retry Now"** for any suspended symbols
4. **Wait 5 minutes** - Allow refresh cycle to complete
5. **Verify updates** - Check if prices update

### If Still Not Working
1. **Click "Clear All Caches"** in Debug tab
2. **Wait 15 minutes** - Allow full refresh cycle
3. **Check Console.app** - Filter for "Stockbar" to see rate limit errors
4. **Report portfolio size** - How many symbols are being tracked?

### For Developer (LATER)
1. **Implement refresh interval UI** (Option 2) - Quick win
2. **Add smart market hours detection** (Option 3) - Better UX
3. **Consider adaptive rate limiting** (Option 1) - Best long-term solution

---

## Expected Behavior After Manual Retry

**Timeline:**
1. **T+0s:** User clicks "Retry Now" for UNH
2. **T+5s:** Suspension cleared, UNH marked for refresh
3. **T+10s:** Next refresh cycle triggers (within 5 minutes)
4. **T+15s:** UNH data fetched from Yahoo Finance
   - **Success:** UNH updates, cache refreshed
   - **Rate limited again:** Exponential backoff starts (1min retry)
5. **T+1min-10min:** Retries with increasing delays if rate limited
6. **After 5 failures:** Circuit breaker activates again (1-hour suspension)

**Success Indicators:**
- UNH timestamp updates to current time
- Price reflects current market data
- Cache status shows "🟢 Fresh (expires in 15m)"

**Failure Indicators:**
- Timestamp remains old
- Cache status shows "🔴 Suspended (failed 5x, resume in XXm)"
- Error message in dropdown: "⚠️ Rate limit reached. Retry in XXs."

---

## Monitoring & Logging

### Check These Logs

**1. Console.app (macOS System Logs):**
```bash
log stream --predicate 'process == "Stockbar"' --level debug
```

**2. Stockbar Debug Log:**
```bash
tail -f ~/Documents/stockbar_debug.log | grep -E "UNH|rate|limit|429|suspend"
```

**3. Network Errors:**
Look for these patterns in logs:
- "Rate limit reached"
- "Too Many Requests"
- "HTTP 429"
- "YFRateLimitError"
- "Suspended (failed 5x"

---

## Summary

**Problem:** Yahoo Finance rate limiting causes stocks (like UNH) to stop updating

**Root Cause:** Too many API requests from refresh strategy with large portfolios

**Immediate Fix:** Use Debug tab → Cache Inspector → "Retry Now" button

**Long-Term Fix:** Implement adaptive refresh intervals or smart market hours detection

**Current Status:** ✅ Mitigation features already in place (backoff, circuit breaker, cache)

**Next Steps:** Test manual retry, then implement refresh interval UI for user control

---

**Generated:** 2025-10-01
**Last Updated:** 2025-10-01
