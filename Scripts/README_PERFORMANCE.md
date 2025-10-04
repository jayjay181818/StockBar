# Performance Testing Guide

## Quick Start

1. **Launch Stockbar**
   - Run Stockbar.app from Applications or Xcode
   - Wait for app to fully load and complete initial data fetch

2. **Run Performance Test**
   ```bash
   cd "/Users/josh/Downloads/Stockbar Claude/Stockbar/Scripts"
   ./measure_performance.sh
   ```

3. **During Test (30 seconds)**
   - Use app normally: view charts, switch tabs, check analytics
   - Interact with menu bar items
   - Open/close preferences
   - This simulates real-world usage

4. **Review Results**
   - Script outputs CPU, memory, and thread metrics
   - Compares against targets:
     - CPU: <5% average
     - Memory: <200 MB
     - Both must pass for green status

## Performance Targets

### CPU Usage
- **Target**: <5% average during normal operation
- **Measurement**: 30-second average, 15 samples
- **Acceptable**: Spikes to 10-20% during refresh are OK
- **Warning**: Sustained >10% indicates optimization needed

### Memory Footprint
- **Target**: <200 MB total
- **Measurement**: Resident Set Size (RSS)
- **Acceptable**: Growth during initial data load is OK
- **Warning**: >250 MB indicates memory leak

### Threads
- **Expected**: 5-15 threads typical for macOS app
- **Acceptable**: Thread count stable over time
- **Warning**: Continuously increasing threads indicates leak

## Detailed Performance Testing

### 1. Idle Performance
Test CPU/memory when app is idle (no user interaction):

```bash
# Launch app, wait 2 minutes for stabilization
# Then run:
./measure_performance.sh
```

**Expected**:
- CPU: 0-2% (nearly idle)
- Memory: 100-150 MB

### 2. Active Usage Performance
Test during normal usage:

```bash
# While script runs, perform these actions:
# - Click menu bar items
# - Open preferences
# - Switch chart types
# - Change analytics time ranges
./measure_performance.sh
```

**Expected**:
- CPU: 2-5% average
- Memory: 120-180 MB

### 3. Stress Test Performance
Test with heavy portfolio:

```bash
# Add 20+ stocks to portfolio
# Enable multiple chart indicators
# View analytics for All Time period
./measure_performance.sh
```

**Expected**:
- CPU: 3-8% average (slightly higher OK)
- Memory: 150-200 MB

### 4. Chart Rendering Performance
Subjective test for responsiveness:

1. Open Charts tab
2. Rapidly switch between chart types (Line → Candlestick → Volume)
3. Change time ranges quickly (1D → 1M → 1Y)

**Expected**:
- No visible lag (<100ms render time)
- Smooth animations
- UI stays responsive

### 5. Menu Bar Update Speed
Test menu bar responsiveness:

1. Trigger manual refresh
2. Observe menu bar update time

**Expected**:
- Menu bar updates within 50ms
- Feels instant to user

### 6. Startup Performance
Test app launch time:

1. Quit Stockbar completely
2. Time the relaunch: `time open -a Stockbar`
3. Wait until menu bar items appear

**Expected**:
- Launch time: <3 seconds
- Menu bar populated: <5 seconds

## Troubleshooting Performance Issues

### High CPU Usage

**Symptoms**: CPU >10% sustained
**Common Causes**:
- Infinite refresh loops
- Inefficient calculations
- Too frequent polling

**Diagnosis**:
```bash
# Monitor with Instruments
open -a Instruments
# Choose "Time Profiler" template
# Attach to Stockbar process
```

**Solutions**:
- Check refresh intervals (should be 15 min minimum)
- Review calculation caching
- Verify background operations are throttled

### High Memory Usage

**Symptoms**: Memory >250 MB or continuously growing
**Common Causes**:
- Memory leaks (retain cycles)
- Unbounded cache growth
- Historical data accumulation

**Diagnosis**:
```bash
# Check for memory leaks with Instruments
open -a Instruments
# Choose "Leaks" template
# Run for 5-10 minutes
```

**Solutions**:
- Review Combine subscriptions for `weak self`
- Check cache size limits
- Verify historical data cleanup runs

### Slow Chart Rendering

**Symptoms**: Lag when switching charts (>100ms)
**Common Causes**:
- Too many data points
- Unoptimized SwiftUI views
- Synchronous calculations on main thread

**Diagnosis**:
```bash
# Check main thread blocking
open -a Instruments
# Choose "System Trace" template
```

**Solutions**:
- Limit chart data points (max 500-1000)
- Move calculations to background actors
- Use `.task` modifiers for async work

## Activity Monitor Analysis

For detailed investigation:

1. **Open Activity Monitor**
   ```bash
   open -a "Activity Monitor"
   ```

2. **Find Stockbar Process**
   - Search for "Stockbar" in process list

3. **Monitor Key Metrics**
   - **CPU %**: Should stay <5%
   - **Memory**: Should be <200 MB
   - **Threads**: Should be stable (5-15)
   - **Energy Impact**: Should be "Low"

4. **Sample Process (if issues)**
   - Select Stockbar process
   - Click gear icon → "Sample Process"
   - Review for bottlenecks

## Performance Benchmarks

### Baseline (v2.2.10)
- CPU: 2-3% average
- Memory: 85-100 MB
- Startup: <2 seconds

### With Phase 1-4 Features (v2.3.0)
- **Target**: CPU: <5% average
- **Target**: Memory: <200 MB
- **Target**: Startup: <3 seconds
- **Acceptable**: Slight increase due to new features

## Automated Performance Monitoring

For continuous monitoring during development:

```bash
# Run in background, log every 5 minutes
while true; do
    date >> performance.log
    ps -p $(pgrep Stockbar) -o %cpu,%mem >> performance.log
    sleep 300
done
```

## Performance Regression Testing

Before each release:

1. Run all performance tests
2. Compare to baseline metrics
3. Document any increases
4. Investigate if >10% degradation

## Notes

- **Acceptable Variance**: ±2% CPU, ±20 MB memory
- **Optimization Priority**: CPU > Memory > Startup time
- **User Impact**: Responsiveness matters more than absolute numbers
- **Context**: Mac specs affect results (test on target hardware)

## Contact

For performance issues or questions:
- Check logs: `~/Library/Application Support/com.fhl43211.Stockbar/stockbar.log`
- Review Debug tab in preferences for real-time metrics
