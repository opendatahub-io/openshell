#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Run a command in its own session and bound cancellation of its process group."""

import argparse
import contextlib
import math
import os
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grace", type=float, default=10)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command or not math.isfinite(args.grace) or args.grace < 0:
        parser.error("a command and a finite, nonnegative grace period are required")

    cancelled = None

    def cancel(signum, _frame):
        nonlocal cancelled
        if cancelled is None:
            cancelled = signum

    signal.signal(signal.SIGINT, cancel)
    signal.signal(signal.SIGTERM, cancel)
    # Inherit all three streams. The shell caller explicitly preserves stdin
    # when launching this supervisor asynchronously.
    try:
        child = subprocess.Popen(command, start_new_session=True)
    except OSError as error:
        print(f"ERROR: cannot start {command[0]}: {error}", file=sys.stderr)
        return 127

    while cancelled is None:
        try:
            status = child.wait(timeout=0.05)
            if cancelled is None:
                return status if status >= 0 else 128 - status
        except subprocess.TimeoutExpired:
            pass

    def send_group(signum):
        try:
            os.killpg(child.pid, signum)
            return True
        except ProcessLookupError:
            return False

    # Child shells may ignore INT when started asynchronously; TERM requests
    # their cleanup consistently. Preserve the original signal in our exit code.
    send_group(signal.SIGTERM)
    deadline = time.monotonic() + args.grace
    while send_group(0):
        child.poll()  # Reap the leader even if descendants are still running.
        if time.monotonic() >= deadline:
            send_group(signal.SIGKILL)
            break
        time.sleep(0.05)
    # Even an uninterruptible kernel wait must not block wrapper cleanup.
    with contextlib.suppress(subprocess.TimeoutExpired):
        child.wait(timeout=1)
    return 128 + cancelled


if __name__ == "__main__":
    sys.exit(main())
