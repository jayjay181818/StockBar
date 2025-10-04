#!/bin/bash

# Stockbar Performance Measurement Script
# Measures CPU usage, memory footprint, and provides insights

echo "=========================================="
echo "Stockbar Performance Measurement"
echo "=========================================="
echo ""

# Check if Stockbar is running
if ! pgrep -x "Stockbar" > /dev/null; then
    echo "❌ Stockbar is not running."
    echo "Please launch Stockbar first, then run this script again."
    exit 1
fi

echo "✅ Stockbar is running"
echo ""

# Get process ID
PID=$(pgrep -x "Stockbar")
echo "Process ID: $PID"
echo ""

# Measure CPU usage over 30 seconds
echo "📊 Measuring CPU usage (30 seconds)..."
echo "   (Please interact with the app normally)"
echo ""

# Sample CPU every 2 seconds for 30 seconds
CPU_SAMPLES=()
for i in {1..15}; do
    CPU=$(ps -p $PID -o %cpu= | awk '{print $1}')
    CPU_SAMPLES+=($CPU)
    echo "   Sample $i/15: ${CPU}%"
    sleep 2
done

echo ""

# Calculate average CPU
TOTAL=0
for cpu in "${CPU_SAMPLES[@]}"; do
    TOTAL=$(echo "$TOTAL + $cpu" | bc)
done
AVG_CPU=$(echo "scale=2; $TOTAL / ${#CPU_SAMPLES[@]}" | bc)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CPU Usage Results:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Average CPU: ${AVG_CPU}%"

# Check against target
if (( $(echo "$AVG_CPU < 5.0" | bc -l) )); then
    echo "   Status: ✅ PASS (Target: <5%)"
else
    echo "   Status: ⚠️  ABOVE TARGET (Target: <5%)"
fi
echo ""

# Measure memory usage
echo "📊 Measuring Memory Usage..."
echo ""

MEMORY_KB=$(ps -p $PID -o rss= | awk '{print $1}')
MEMORY_MB=$(echo "scale=2; $MEMORY_KB / 1024" | bc)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Memory Usage Results:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Memory: ${MEMORY_MB} MB"

# Check against target
if (( $(echo "$MEMORY_MB < 200.0" | bc -l) )); then
    echo "   Status: ✅ PASS (Target: <200 MB)"
else
    echo "   Status: ⚠️  ABOVE TARGET (Target: <200 MB)"
fi
echo ""

# Thread count
THREADS=$(ps -M $PID | wc -l)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Thread Usage:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Active Threads: $THREADS"
echo ""

# Summary
echo "=========================================="
echo "Performance Summary"
echo "=========================================="
echo ""
echo "Metric           | Value      | Target    | Status"
echo "─────────────────┼────────────┼───────────┼────────"
printf "CPU Usage        | %-10s | <5%%       | " "${AVG_CPU}%"
if (( $(echo "$AVG_CPU < 5.0" | bc -l) )); then
    echo "✅ PASS"
else
    echo "⚠️  FAIL"
fi

printf "Memory Usage     | %-10s | <200 MB   | " "${MEMORY_MB} MB"
if (( $(echo "$MEMORY_MB < 200.0" | bc -l) )); then
    echo "✅ PASS"
else
    echo "⚠️  FAIL"
fi

echo ""
echo "=========================================="
echo ""
echo "💡 Tips for optimization:"
echo "   - CPU usage should remain low during idle periods"
echo "   - Memory should stabilize after initial data loading"
echo "   - Check Activity Monitor for detailed breakdown"
echo ""
echo "Measurement complete!"
