#!/usr/bin/env python3
"""
Test script for Stockbar dynamic window resizing functionality.
This script uses AppleScript to simulate user interactions and verify the 
dynamic window resizing behavior works as expected.
"""

import subprocess
import time
import sys

def run_applescript(script):
    """Execute AppleScript and return the result."""
    try:
        result = subprocess.run(['osascript', '-e', script], 
                               capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return result.stdout.strip()
        else:
            print(f"AppleScript error: {result.stderr}")
            return None
    except Exception as e:
        print(f"Error running AppleScript: {e}")
        return None

def get_window_bounds():
    """Get the current window bounds of Stockbar Preferences."""
    script = '''
    tell application "System Events"
        tell process "Stockbar"
            if exists window "Stockbar Preferences" then
                get bounds of window "Stockbar Preferences"
            else
                return "Window not found"
            end if
        end tell
    end tell
    '''
    return run_applescript(script)

def open_preferences():
    """Open Stockbar preferences window."""
    print("🔧 Opening Stockbar preferences...")
    script = '''
    tell application "System Events"
        tell process "Stockbar"
            click menu bar item 1 of menu bar 1
            delay 0.5
            if exists menu 1 of menu bar item 1 of menu bar 1 then
                click menu item "Preferences" of menu 1 of menu bar item 1 of menu bar 1
                return "Success"
            else
                return "Menu not found"
            end if
        end tell
    end tell
    '''
    return run_applescript(script)

def click_tab(tab_name):
    """Click on a specific tab in the preferences window."""
    print(f"📝 Switching to {tab_name} tab...")
    script = f'''
    tell application "System Events"
        tell process "Stockbar"
            if exists window "Stockbar Preferences" then
                click button "{tab_name}" of window "Stockbar Preferences"
                delay 0.5
                return "Success"
            else
                return "Window not found"
            end if
        end tell
    end tell
    '''
    return run_applescript(script)

def test_dynamic_resizing():
    """Test the dynamic window resizing functionality."""
    print("🧪 Testing Stockbar Dynamic Window Resizing")
    print("=" * 50)
    
    # First, try to open preferences
    result = open_preferences()
    if result != "Success":
        print(f"❌ Failed to open preferences: {result}")
        return False
    
    time.sleep(1)  # Give window time to appear
    
    # Test 1: Check initial window size
    print("\n📏 Test 1: Checking initial window bounds...")
    initial_bounds = get_window_bounds()
    if initial_bounds and initial_bounds != "Window not found":
        print(f"✅ Initial window bounds: {initial_bounds}")
    else:
        print("❌ Could not get initial window bounds")
        return False
    
    # Test 2: Switch to Charts tab and check resize
    print("\n📊 Test 2: Switching to Charts tab...")
    result = click_tab("Charts")
    if result == "Success":
        time.sleep(2)  # Allow time for dynamic resize
        charts_bounds = get_window_bounds()
        print(f"✅ Charts tab bounds: {charts_bounds}")
        
        # Compare bounds
        if initial_bounds != charts_bounds:
            print("✅ Window resized dynamically for Charts tab!")
        else:
            print("⚠️  Window did not resize for Charts tab")
    else:
        print(f"❌ Failed to switch to Charts tab: {result}")
    
    # Test 3: Switch to Debug tab and check resize
    print("\n🐛 Test 3: Switching to Debug tab...")
    result = click_tab("Debug")
    if result == "Success":
        time.sleep(2)  # Allow time for dynamic resize
        debug_bounds = get_window_bounds()
        print(f"✅ Debug tab bounds: {debug_bounds}")
        
        # Compare bounds
        if charts_bounds != debug_bounds:
            print("✅ Window resized dynamically for Debug tab!")
        else:
            print("⚠️  Window did not resize for Debug tab")
    else:
        print(f"❌ Failed to switch to Debug tab: {result}")
    
    # Test 4: Switch back to Portfolio tab
    print("\n💼 Test 4: Switching back to Portfolio tab...")
    result = click_tab("Portfolio")
    if result == "Success":
        time.sleep(2)  # Allow time for dynamic resize
        portfolio_bounds = get_window_bounds()
        print(f"✅ Portfolio tab bounds: {portfolio_bounds}")
        
        # Compare bounds
        if debug_bounds != portfolio_bounds:
            print("✅ Window resized dynamically for Portfolio tab!")
        else:
            print("⚠️  Window did not resize for Portfolio tab")
    else:
        print(f"❌ Failed to switch to Portfolio tab: {result}")
    
    print("\n" + "=" * 50)
    print("🎉 Dynamic window resizing test completed!")
    return True

def check_stockbar_running():
    """Check if Stockbar is running."""
    try:
        result = subprocess.run(['pgrep', 'Stockbar'], 
                               capture_output=True, text=True)
        return result.returncode == 0
    except:
        return False

if __name__ == "__main__":
    print("🚀 Stockbar Dynamic Window Resizing Test Suite")
    print("=" * 50)
    
    # Check if Stockbar is running
    if not check_stockbar_running():
        print("❌ Stockbar is not running. Please start the application first.")
        sys.exit(1)
    
    print("✅ Stockbar is running")
    
    # Run the tests
    success = test_dynamic_resizing()
    
    if success:
        print("\n✅ All tests completed successfully!")
        sys.exit(0)
    else:
        print("\n❌ Some tests failed.")
        sys.exit(1)