# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Check stdin inheritance and cancellation of E2E process groups."""

import contextlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class ProcessGroupTests(unittest.TestCase):
    def test_background_child_preserves_stdin(self):
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; e2e_run_child cat',
                "bash",
                str(ROOT / "e2e/support/child-process.sh"),
            ],
            env=dict(os.environ, PYTHON_BIN=sys.executable),
            input="input for the test process\n",
            text=True,
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "input for the test process\n")

    @unittest.skipUnless(sys.platform == "linux", "checks process state through procfs")
    def test_termination_kills_uncooperative_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "pids.json"
            ready = Path(directory) / "ready"
            descendant = (
                "import pathlib,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                f"pathlib.Path({str(ready)!r}).touch(); time.sleep(60)"
            )
            command = (
                "import json,os,pathlib,signal,subprocess,sys,time\n"
                "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                f"child=subprocess.Popen([sys.executable,'-c',{descendant!r}])\n"
                f"while not pathlib.Path({str(ready)!r}).exists(): time.sleep(0.01)\n"
                f"pathlib.Path({str(pid_file)!r}).write_text(json.dumps([os.getpid(),child.pid]))\n"
                "child.wait()\n"
            )
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(ROOT / "e2e/support/run-child.py"),
                    "--grace",
                    "0.2",
                    "--",
                    sys.executable,
                    "-c",
                    command,
                ],
                start_new_session=True,
            )
            pids = []
            try:
                deadline = time.monotonic() + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(pid_file.exists(), "descendant did not start")
                pids = json.loads(pid_file.read_text())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=3), 143)
                for pid in pids:
                    try:
                        state = (
                            Path(f"/proc/{pid}/stat")
                            .read_text()
                            .split(") ", 1)[1]
                            .split()[0]
                        )
                    except FileNotFoundError:
                        continue
                    self.assertEqual(state, "Z", f"process {pid} survived cancellation")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                for pid in pids:
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(pid, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
