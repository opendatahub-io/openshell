#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Strip skipped testcases from a JUnit report, keeping it self-consistent.

DevTestOps CI parses the XML and would create a Jira for every skipped
case, so the python lane removes them after the run. Each suite's
attributes (tests/skipped/failures/errors/time) are recomputed from the
surviving cases so the report does not disagree with itself once
merge-e2e-odh-reports.py recalculates the root totals from surviving
cases; the number of stripped cases is printed to stderr for audit.

Exit codes: 0 = at least one executed case remains, 1 = every collected
case was skipped (vacuous pass), 2 = the report cannot be parsed.
"""

from __future__ import annotations

import contextlib
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


def strip_skipped(path: str) -> int:
    """Remove skipped cases from `path` in place; return executed cases."""
    tree = ET.parse(path)
    root = tree.getroot()
    suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")
    executed = 0
    stripped = 0
    for suite in suites:
        kept = failures = errors = 0
        time_total = 0.0
        for case in list(suite.findall("testcase")):
            if case.find("skipped") is not None:
                suite.remove(case)
                stripped += 1
                continue
            kept += 1
            if case.find("failure") is not None:
                failures += 1
            if case.find("error") is not None:
                errors += 1
            with contextlib.suppress(ValueError):
                time_total += float(case.get("time", "0"))
        executed += kept
        suite.set("tests", str(kept))
        suite.set("skipped", "0")
        suite.set("failures", str(failures))
        suite.set("errors", str(errors))
        suite.set("time", f"{time_total:.6f}")
    ET.indent(tree, space="    ")
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=Path(path).parent,
            prefix=f".{Path(path).name}.",
            delete=False,
        ) as stream:
            temp_path = Path(stream.name)
            tree.write(stream, encoding="utf-8", xml_declaration=True)
        temp_path.replace(path)
    except OSError:
        if temp_path is not None:
            with contextlib.suppress(FileNotFoundError):
                temp_path.unlink()
        raise
    print(
        f"stripped {stripped} skipped testcase(s); {executed} executed remain",
        file=sys.stderr,
    )
    return executed


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {argv[0]} <report.xml>", file=sys.stderr)
        return 2
    try:
        executed = strip_skipped(argv[1])
    except ET.ParseError as error:
        print(f"{argv[1]}: cannot parse JUnit report: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"{argv[1]}: cannot read or write JUnit report: {error}", file=sys.stderr)
        return 2
    return 0 if executed > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
