"""Long-lived runner for Stockbar's market-data scripts.

Starting Python and importing yfinance and its dependencies costs about half a
second, and the app used to pay it for every quote, history and OHLC request.
This worker pays it once: it stays running, and the app sends one request per
line on stdin:

    {"id": 1, "script": "get_stock_data.py", "args": ["--json", "AAPL"]}

Each request runs the named script exactly as `python3 <script> <args...>`
would: fresh module globals, `sys.argv` set, stdout and stderr captured and an
exit code from `sys.exit`. Imported packages stay loaded between requests, so
only the script's own module code runs again, and it rereads its configuration
and API keys each time. The reply is one JSON line on the original stdout:

    {"id": 1, "exit_code": 0, "stdout": "...", "stderr": "..."}

Only scripts next to this file, from SCRIPTS, can be run. The worker exits when
stdin closes, so it never outlives the app.
"""
import builtins
import io
import json
import os
import sys
import traceback

SCRIPTS = ("get_stock_data.py", "get_ohlc_data.py")
SCRIPT_DIRECTORY = os.path.dirname(os.path.abspath(__file__))


def preload():
    """Import the heavy shared packages before the first request arrives."""
    for name in ("requests", "yfinance"):
        try:
            __import__(name)
        except Exception:
            # The script reports a missing package in its own output.
            pass


def compiled_script(name, cache):
    if name not in SCRIPTS:
        raise ValueError(f"unknown script: {name!r}")
    if name not in cache:
        path = os.path.join(SCRIPT_DIRECTORY, name)
        with open(path, "r", encoding="utf-8") as handle:
            cache[name] = (path, compile(handle.read(), path, "exec"))
    return cache[name]


def exit_code_from(status, stderr):
    """Map a SystemExit status the way the interpreter does."""
    if status is None:
        return 0
    if isinstance(status, int):
        return status
    print(status, file=stderr)
    return 1


def run_script(name, args, cache):
    path, code = compiled_script(name, cache)
    stdout = io.StringIO()
    stderr = io.StringIO()
    saved = (sys.argv, sys.stdout, sys.stderr)
    exit_code = 0
    try:
        sys.argv = [path] + [str(arg) for arg in args]
        sys.stdout, sys.stderr = stdout, stderr
        exec(code, {"__name__": "__main__", "__file__": path, "__builtins__": builtins})
    except SystemExit as error:
        exit_code = exit_code_from(error.code, stderr)
    except Exception:
        traceback.print_exc(file=stderr)
        exit_code = 1
    finally:
        sys.argv, sys.stdout, sys.stderr = saved
    return exit_code, stdout.getvalue(), stderr.getvalue()


def serve(requests, replies):
    cache = {}
    for line in requests:
        line = line.strip()
        if not line:
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = request["id"]
            args = request.get("args", [])
            if not isinstance(args, list):
                raise ValueError("args must be a list")
            exit_code, out, err = run_script(request["script"], args, cache)
        except Exception as error:
            exit_code, out, err = 2, "", f"stockbar_worker: invalid request: {error}\n"
        replies.write(json.dumps({"id": request_id, "exit_code": exit_code, "stdout": out, "stderr": err}) + "\n")
        replies.flush()


def main():
    # Keep the reply channel private: anything else that writes to file
    # descriptor 1 (a C extension, a stray subprocess) goes to stderr instead
    # of corrupting a reply.
    replies = os.fdopen(os.dup(1), "w", encoding="utf-8")
    os.dup2(2, 1)
    preload()
    requests = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8")
    serve(requests, replies)


if __name__ == "__main__":
    main()
