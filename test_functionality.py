#!/usr/bin/env python3
"""
Test script for Stockbar functionality without UI automation.
This script tests the core functionality we can verify programmatically.
"""

import subprocess
import time
import os
import json

def test_python_backend():
    """Test the Python backend for stock data fetching."""
    print("🐍 Testing Python Backend...")
    
    test_symbols = ["AAPL", "GOOGL", "MSFT"]
    
    for symbol in test_symbols:
        try:
            result = subprocess.run([
                'python3', 'Stockbar/Resources/get_stock_data.py', symbol
            ], capture_output=True, text=True, timeout=10)
            
            if result.returncode == 0 and "Close:" in result.stdout:
                print(f"  ✅ {symbol}: Stock data fetched successfully")
            else:
                print(f"  ❌ {symbol}: Failed to fetch stock data")
                if result.stderr:
                    print(f"     Error: {result.stderr}")
                    
        except subprocess.TimeoutExpired:
            print(f"  ⏰ {symbol}: Request timed out")
        except Exception as e:
            print(f"  ❌ {symbol}: Exception occurred: {e}")

def test_batch_fetching():
    """Test batch stock data fetching."""
    print("\n📦 Testing Batch Stock Data Fetching...")
    
    try:
        result = subprocess.run([
            'python3', 'Stockbar/Resources/get_stock_data.py', 
            'AAPL', 'GOOGL', 'MSFT'
        ], capture_output=True, text=True, timeout=15)
        
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            symbols_found = [line for line in lines if '@' in line and 'Close:' in line]
            
            if len(symbols_found) >= 3:
                print(f"  ✅ Batch processing successful: {len(symbols_found)} symbols processed")
                for line in symbols_found:
                    symbol = line.split('@')[0].strip()
                    print(f"    📊 {symbol}: Data retrieved")
            else:
                print(f"  ⚠️  Partial success: {len(symbols_found)} symbols processed")
        else:
            print("  ❌ Batch processing failed")
            
    except Exception as e:
        print(f"  ❌ Batch processing exception: {e}")

def check_dependencies():
    """Check if required dependencies are installed."""
    print("\n🔍 Checking Dependencies...")
    
    dependencies = {
        'yfinance': 'yfinance',
        'pandas': 'pandas',
        'requests': 'requests'
    }
    
    for name, module in dependencies.items():
        try:
            result = subprocess.run([
                'python3', '-c', f'import {module}; print("OK")'
            ], capture_output=True, text=True, timeout=5)
            
            if result.returncode == 0 and "OK" in result.stdout:
                print(f"  ✅ {name}: Installed and working")
            else:
                print(f"  ❌ {name}: Not working properly")
                
        except Exception as e:
            print(f"  ❌ {name}: Error checking: {e}")

def test_configuration_files():
    """Test configuration file handling."""
    print("\n⚙️  Testing Configuration Files...")
    
    # Check if UserDefaults can be read (this tests the Swift configuration system)
    config_files = [
        os.path.expanduser("~/Documents/stockbar_config.json"),
        os.path.expanduser("~/Documents/stockbar.log"),
    ]
    
    for config_file in config_files:
        if os.path.exists(config_file):
            try:
                size = os.path.getsize(config_file)
                print(f"  ✅ {os.path.basename(config_file)}: Exists ({size} bytes)")
            except Exception as e:
                print(f"  ⚠️  {os.path.basename(config_file)}: Exists but unreadable: {e}")
        else:
            print(f"  ℹ️  {os.path.basename(config_file)}: Not found (will be created when needed)")

def test_cache_functionality():
    """Test the cache functionality."""
    print("\n💾 Testing Cache Functionality...")
    
    cache_file = os.path.expanduser("~/.stockbar_cache.json")
    
    # Delete cache if it exists to test fresh creation
    if os.path.exists(cache_file):
        try:
            os.remove(cache_file)
            print("  🗑️  Cleared existing cache")
        except:
            print("  ⚠️  Could not clear existing cache")
    
    # Test cache creation by fetching data
    try:
        result = subprocess.run([
            'python3', 'Stockbar/Resources/get_stock_data.py', 'AAPL'
        ], capture_output=True, text=True, timeout=10)
        
        if result.returncode == 0:
            time.sleep(1)  # Give cache time to be written
            
            if os.path.exists(cache_file):
                try:
                    with open(cache_file, 'r') as f:
                        cache_data = json.load(f)
                    print(f"  ✅ Cache created successfully with {len(cache_data)} entries")
                    
                    # Test cache usage by fetching same data again
                    start_time = time.time()
                    result2 = subprocess.run([
                        'python3', 'Stockbar/Resources/get_stock_data.py', 'AAPL'
                    ], capture_output=True, text=True, timeout=10)
                    end_time = time.time()
                    
                    if result2.returncode == 0:
                        print(f"  ✅ Cache retrieval successful ({end_time - start_time:.2f}s)")
                    else:
                        print("  ⚠️  Cache retrieval failed")
                        
                except json.JSONDecodeError:
                    print("  ❌ Cache file is corrupted")
                except Exception as e:
                    print(f"  ❌ Cache reading error: {e}")
            else:
                print("  ⚠️  Cache file was not created")
        else:
            print("  ❌ Failed to trigger cache creation")
            
    except Exception as e:
        print(f"  ❌ Cache testing exception: {e}")

def check_app_processes():
    """Check Stockbar application processes."""
    print("\n🔄 Checking Application Processes...")
    
    try:
        result = subprocess.run(['pgrep', '-l', 'Stockbar'], 
                               capture_output=True, text=True)
        
        if result.returncode == 0:
            processes = result.stdout.strip().split('\n')
            print(f"  ✅ Stockbar is running ({len(processes)} process(es))")
            for process in processes:
                pid, name = process.split(' ', 1)
                print(f"    🔹 PID {pid}: {name}")
        else:
            print("  ❌ Stockbar is not running")
            
    except Exception as e:
        print(f"  ❌ Error checking processes: {e}")

def main():
    """Run all functionality tests."""
    print("🧪 Stockbar Functionality Test Suite")
    print("=" * 50)
    
    check_app_processes()
    check_dependencies()
    test_python_backend()
    test_batch_fetching()
    test_cache_functionality()
    test_configuration_files()
    
    print("\n" + "=" * 50)
    print("✨ Functionality testing completed!")
    print("\n📝 Manual Testing Recommendations:")
    print("   1. Click on the Stockbar menu bar icon")
    print("   2. Select 'Preferences' to open the preferences window")
    print("   3. Test switching between Portfolio, Charts, and Debug tabs")
    print("   4. Observe automatic window resizing when switching tabs")
    print("   5. Add/remove portfolio trades and observe window adjustments")
    print("   6. In Charts tab, toggle Performance Metrics and Export Options")
    print("   7. Verify window resizes appropriately for content changes")

if __name__ == "__main__":
    main()