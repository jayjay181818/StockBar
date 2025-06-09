#!/usr/bin/env python3
import subprocess
import json

# Get the raw data from defaults
result = subprocess.run(['defaults', 'export', 'com.fhl43211.Stockbar', '-'], capture_output=True, text=True)
if result.returncode == 0:
    try:
        plist_data = result.stdout
        # Look for usertrades in the plist
        if 'usertrades' in plist_data:
            print("Found usertrades in UserDefaults")
            # Try to extract and decode
            lines = plist_data.split('\n')
            for i, line in enumerate(lines):
                if 'usertrades' in line and i+1 < len(lines):
                    data_line = lines[i+1].strip()
                    if data_line.startswith('<') and data_line.endswith('>'):
                        # This is base64 encoded data
                        import base64
                        hex_data = data_line[1:-1]  # Remove < >
                        try:
                            # Convert hex to bytes
                            data = bytes.fromhex(hex_data.replace(' ', ''))
                            # Try to decode as JSON
                            json_str = data.decode('utf-8')
                            trades = json.loads(json_str)
                            print(f'Found {len(trades)} trades:')
                            for trade in trades:
                                print(f'  - {trade.get("name", "Unknown")}')
                            break
                        except Exception as e:
                            print(f'Error decoding hex data: {e}')
                            print(f'Hex data: {hex_data[:100]}...')
        else:
            print("No usertrades found in UserDefaults")
    except Exception as e:
        print(f'Error processing plist: {e}')
else:
    print('Error reading UserDefaults') 