import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest


WORKER_PATH = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "Stockbar", "Resources", "stockbar_worker.py")
)

FAKE_SCRIPT = """
import sys
RUNS = globals().get("RUNS", 0) + 1
args = sys.argv[1:]
if args[:1] == ["--exit"]:
    sys.exit(int(args[1]) if args[1].isdigit() else args[1])
if args[:1] == ["--raise"]:
    raise RuntimeError("boom")
print("runs=%d args=%s" % (RUNS, ",".join(args)))
print("note", file=sys.stderr)
"""


def load_worker(script_directory):
    spec = importlib.util.spec_from_file_location("stockbar_worker_test", WORKER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.SCRIPT_DIRECTORY = script_directory
    return module


class StockbarWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        with open(os.path.join(self.temp_directory.name, "get_stock_data.py"), "w", encoding="utf-8") as handle:
            handle.write(FAKE_SCRIPT)
        self.worker = load_worker(self.temp_directory.name)

    def tearDown(self):
        self.temp_directory.cleanup()

    def serve(self, *requests):
        lines = io.StringIO("".join(json.dumps(request) + "\n" for request in requests))
        replies = io.StringIO()
        self.worker.serve(lines, replies)
        return [json.loads(line) for line in replies.getvalue().splitlines()]

    def test_each_request_runs_the_script_with_fresh_globals(self):
        replies = self.serve(
            {"id": 1, "script": "get_stock_data.py", "args": ["--json", "AAPL"]},
            {"id": 2, "script": "get_stock_data.py", "args": ["MSFT"]},
        )

        self.assertEqual([reply["id"] for reply in replies], [1, 2])
        self.assertEqual(replies[0]["stdout"], "runs=1 args=--json,AAPL\n")
        self.assertEqual(replies[1]["stdout"], "runs=1 args=MSFT\n")
        self.assertEqual(replies[0]["stderr"], "note\n")
        self.assertEqual(replies[0]["exit_code"], 0)

    def test_exit_status_matches_the_interpreter(self):
        replies = self.serve(
            {"id": 1, "script": "get_stock_data.py", "args": ["--exit", "3"]},
            {"id": 2, "script": "get_stock_data.py", "args": ["--exit", "message"]},
            {"id": 3, "script": "get_stock_data.py", "args": ["--raise"]},
        )

        self.assertEqual(replies[0]["exit_code"], 3)
        self.assertEqual(replies[1]["exit_code"], 1)
        self.assertEqual(replies[1]["stderr"], "message\n")
        self.assertEqual(replies[2]["exit_code"], 1)
        self.assertIn("RuntimeError: boom", replies[2]["stderr"])

    def test_only_known_scripts_beside_the_worker_run(self):
        replies = self.serve(
            {"id": 1, "script": "../get_stock_data.py", "args": []},
            {"id": 2, "script": "get_ohlc_data.py", "args": []},
            {"id": 3, "script": "get_stock_data.py", "args": "not a list"},
        )

        self.assertEqual([reply["exit_code"] for reply in replies], [2, 2, 2])
        self.assertIn("unknown script", replies[0]["stderr"])
        self.assertTrue(all(reply["stdout"] == "" for reply in replies))

    def test_malformed_line_gets_an_error_reply_and_serving_continues(self):
        lines = io.StringIO("not json\n" + json.dumps({"id": 7, "script": "get_stock_data.py", "args": []}) + "\n")
        replies = io.StringIO()

        self.worker.serve(lines, replies)

        first, second = [json.loads(line) for line in replies.getvalue().splitlines()]
        self.assertIsNone(first["id"])
        self.assertEqual(first["exit_code"], 2)
        self.assertEqual(second["id"], 7)
        self.assertEqual(second["exit_code"], 0)

    def test_stray_writes_to_stdout_do_not_corrupt_replies(self):
        directory = self.temp_directory.name
        with open(os.path.join(directory, "stockbar_worker.py"), "w", encoding="utf-8") as handle:
            with open(WORKER_PATH, encoding="utf-8") as source:
                handle.write(source.read())
        with open(os.path.join(directory, "get_stock_data.py"), "w", encoding="utf-8") as handle:
            handle.write("import os\nos.write(1, b'stray\\n')\nprint('ok')\n")

        completed = subprocess.run(
            [sys.executable, os.path.join(directory, "stockbar_worker.py")],
            input=json.dumps({"id": 1, "script": "get_stock_data.py", "args": []}) + "\n",
            capture_output=True,
            text=True,
            timeout=60,
        )

        reply = json.loads(completed.stdout)
        self.assertEqual(reply["stdout"], "ok\n")
        self.assertIn("stray", completed.stderr)
        self.assertEqual(completed.returncode, 0, "The worker exits cleanly when stdin closes")


if __name__ == "__main__":
    unittest.main()
