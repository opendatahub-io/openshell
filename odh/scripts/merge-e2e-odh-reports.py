#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Merge ordered phase JUnit files into one tier report and HTML summary."""

from __future__ import annotations

import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from copy import deepcopy
from pathlib import Path


def merge(tier: str, paths: list[Path], results_dir: Path) -> Path:
    if not paths:
        raise ValueError("at least one phase report is required")
    suites: list[ET.Element] = []
    cases: list[ET.Element] = []
    for path in paths:
        if not path.is_file():
            print(f"WARNING: skipping missing phase report: {path}", file=sys.stderr)
            continue
        root = ET.parse(path).getroot()
        if root.tag == "testsuite":
            suites.append(deepcopy(root))
        elif root.tag == "testsuites":
            children = [child for child in root if child.tag == "testsuite"]
            if not children:
                raise ValueError(f"JUnit report has no testsuite elements: {path}")
            suites.extend(deepcopy(child) for child in children)
        else:
            raise ValueError(f"unsupported JUnit root {root.tag!r}: {path}")
    if not suites:
        raise ValueError("no phase reports were available to merge")
    for suite in suites:
        cases.extend(suite.iter("testcase"))
    totals = {
        "tests": len(cases),
        "failures": sum(1 for case in cases for child in case if child.tag == "failure"),
        "errors": sum(1 for case in cases for child in case if child.tag == "error"),
        "skipped": sum(1 for case in cases for child in case if child.tag == "skipped"),
        "time": f"{sum(float(case.get('time', '0')) for case in cases):.6f}",
    }
    root = ET.Element("testsuites", {key: str(value) for key, value in totals.items()})
    for suite in suites:
        root.append(suite)
    xml_bytes = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    results_dir.mkdir(parents=True, exist_ok=True)
    xml_path = results_dir / f"e2e-odh-{tier}.xml"
    fd, temporary = tempfile.mkstemp(prefix=f".{xml_path.name}.", dir=results_dir)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(xml_bytes)
        os.replace(temporary, xml_path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    return xml_path


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("Usage: merge-e2e-odh-reports.py <tier> <phase-report.xml>...", file=sys.stderr)
        return 2
    tier = argv[1]
    if not tier.replace("-", "").replace("_", "").isalnum():
        print(f"invalid tier name: {tier!r}", file=sys.stderr)
        return 2
    results_dir = Path(os.environ.get("OPENSHELL_E2E_RESULTS_DIR", Path(__file__).resolve().parents[2] / "results"))
    try:
        xml_path = merge(tier, [Path(arg) for arg in argv[2:]], results_dir)
    except (OSError, ET.ParseError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"JUnit report: {xml_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
