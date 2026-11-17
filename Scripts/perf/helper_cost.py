#!/usr/bin/env python3
"""Measure what one start of Stockbar's Python helper costs, without the network.

    python3 Scripts/perf/helper_cost.py <interpreter> <stockbar_worker.py> <proc_usage>

Starts the worker the way the app does, waits until its imports are done, and
reports the time and CPU that took and the memory it then holds. Readiness is
detected with a request for a script the worker refuses, which it answers
straight after its imports; no market-data script runs.
"""
import os
import subprocess
import sys
import time


def started_usage(command, proc_usage, first_request=None):
    """Start `command`, wait for its first line of output, and read what the process holds.

    Returns the seconds it took to answer and the sampler's fields.
    """
    environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG") if key in os.environ}
    environment.update(PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1")
    started = time.perf_counter()
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env=environment,
    )
    try:
        if first_request is not None:
            process.stdin.write(first_request)
            process.stdin.flush()
        if not process.stdout.readline():
            sys.exit(f"{os.path.basename(command[0])} exited before answering.")
        ready = time.perf_counter() - started
        usage = subprocess.run([proc_usage, str(process.pid)], capture_output=True, text=True, check=True).stdout
    finally:
        process.stdin.close()
        process.wait(timeout=10)
    return ready, dict(line.split("=", 1) for line in usage.splitlines() if "=" in line)


def measure(interpreter, worker, proc_usage):
    ready, fields = started_usage(
        [interpreter, worker], proc_usage, b'{"id": 1, "script": "none", "args": []}\n',
    )
    return {
        "helper_start_s": f"{ready:.2f}",
        "helper_start_cpu_s": fields["app_cpu_s_before_window"],
        "helper_footprint_mb": fields["app_footprint_mb_median"],
        "helper_resident_mb": fields["app_resident_mb_median"],
    }


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("Usage: " + __doc__.strip().splitlines()[2].strip())
    for key, value in measure(*sys.argv[1:]).items():
        print(f"{key}={value}")
