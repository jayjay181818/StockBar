#!/usr/bin/env python3
"""Summarise an `xccov view --report --json` file for the app target.

Prints the overall line coverage and the largest files with the least of it,
which is where a missing test is most likely to hide a fault.
"""
import json
import sys


def summarise(report, largest=25):
    targets = [t for t in report.get('targets', []) if t.get('name', '').endswith('.app')]
    if not targets:
        return ['No app target found in the coverage report.']
    target = targets[0]
    lines = [
        f"{target['name']}: {target['lineCoverage'] * 100:.1f}% of "
        f"{target['executableLines']} executable lines covered",
        '',
        f'Largest {largest} files, least covered first:',
    ]
    files = sorted(target.get('files', []), key=lambda f: f['executableLines'], reverse=True)[:largest]
    for item in sorted(files, key=lambda f: f['lineCoverage']):
        lines.append(
            f"  {item['lineCoverage'] * 100:5.1f}%  {item['executableLines']:6d} lines  {item['name']}"
        )
    return lines


def main(argv):
    if len(argv) != 2:
        print('usage: coverage_summary.py <coverage.json>', file=sys.stderr)
        return 64
    with open(argv[1], encoding='utf-8') as handle:
        report = json.load(handle)
    print('\n'.join(summarise(report)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
