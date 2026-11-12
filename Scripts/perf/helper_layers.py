#!/usr/bin/env python3
"""Show what each layer of the Python helper's imports holds, beside compiled floors.

    python3 Scripts/perf/helper_layers.py <interpreter> <proc_usage> [--runs 5] [--floor "label=program" ...]

Starts the helper's interpreter with one more layer of its imports each time,
waits until the imports are done, and reads the memory the process then holds,
the CPU it used and the time it took, with the sampler the benchmark uses. No
market-data code runs and nothing touches the network.

Each --floor is a compiled program that writes one line and then waits, such as
native_floor.swift or native_floor.rs once compiled: what a helper with no
interpreter starts from.
"""
import argparse
import statistics

from helper_cost import started_usage

LAYERS = [
    ("Interpreter only", "pass"),
    ("+ the standard library modules the helper uses",
     "import json, urllib.request, urllib.parse, csv, re, threading, fcntl, tempfile"),
    ("+ requests", "import json, urllib.request, requests"),
    ("+ pandas", "import json, urllib.request, requests, pandas"),
    ("+ yfinance: everything the helper imports", "import json, urllib.request, requests, yfinance"),
]
READY = "import sys; sys.stdout.write('r\\n'); sys.stdout.flush(); sys.stdin.readline()"


def parse_floor(text):
    label, separator, program = text.partition("=")
    if not separator or not label or not program:
        raise argparse.ArgumentTypeError('a floor is written "label=program"')
    return label, program


def measure(command, proc_usage, runs):
    """Median and range, over `runs` starts, of memory (MB), CPU (s) and time to ready (s)."""
    samples = []
    for _ in range(runs):
        ready, fields = started_usage(command, proc_usage)
        samples.append((float(fields["app_footprint_mb_median"]), float(fields["app_cpu_s_before_window"]), ready))
    return [(statistics.median(column), min(column), max(column)) for column in zip(*samples)]


def table(interpreter, proc_usage, runs, floors=(), layers=None):
    commands = [(label, [interpreter, "-c", f"{imports}; {READY}"]) for label, imports in layers or LAYERS]
    commands += [(label, [program]) for label, program in floors]
    lines = [
        f"| Process | Memory held: median (range) of {runs} starts | CPU to ready | Time to ready |",
        "| --- | --- | --- | --- |",
    ]
    for label, command in commands:
        memory, cpu, ready = measure(command, proc_usage, runs)
        lines.append(
            f"| {label} | {memory[0]:.1f} ({memory[1]:.1f} to {memory[2]:.1f}) MB "
            f"| {cpu[0]:.2f} ({cpu[1]:.2f} to {cpu[2]:.2f}) s "
            f"| {ready[0]:.2f} ({ready[1]:.2f} to {ready[2]:.2f}) s |"
        )
    return lines


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("interpreter")
    parser.add_argument("proc_usage")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--floor", type=parse_floor, action="append", default=[])
    arguments = parser.parse_args()
    print("\n".join(table(arguments.interpreter, arguments.proc_usage, arguments.runs, arguments.floor)))
