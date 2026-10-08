# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Skip upstream Python tests that cannot run in the ODH OpenShift environment.

Gates are data in the TOML file named by ``OPENSHELL_ODH_PYTHON_GATES``. Each
gate lists exact test node IDs (without parametrization) and the reason they
are unsupported. Matching tests are reported as skipped with that reason, so
unsupported coverage never appears as a pass. With
``OPENSHELL_ODH_PYTHON_GATES_STRICT=1``, a listed test that no longer exists
fails collection, which keeps the gate list from going stale silently.
Upstream test files are never edited.
"""

from __future__ import annotations

import os
import re
import tomllib
from pathlib import Path

import pytest

GATES_ENV = "OPENSHELL_ODH_PYTHON_GATES"
STRICT_ENV = "OPENSHELL_ODH_PYTHON_GATES_STRICT"
_CATEGORY = re.compile(r"[a-z][a-z0-9-]*\Z")


def load_gates(path: Path) -> dict[str, tuple[str, str]]:
    """Return ``{node_id: (category, reason)}`` from a validated gate file."""
    with path.open("rb") as stream:
        raw = tomllib.load(stream)
    gates = raw.get("gate", [])
    if not isinstance(gates, list):
        raise pytest.UsageError(f"{path}: 'gate' must be an array of tables")
    selected: dict[str, tuple[str, str]] = {}
    for gate in gates:
        category = gate.get("category")
        reason = gate.get("reason")
        tests = gate.get("tests")
        if not isinstance(category, str) or not _CATEGORY.fullmatch(category):
            raise pytest.UsageError(f"{path}: invalid gate category {category!r}")
        if not isinstance(reason, str) or not reason.strip():
            raise pytest.UsageError(f"{path}: gate {category!r} needs a reason")
        if not isinstance(tests, list) or not tests:
            raise pytest.UsageError(f"{path}: gate {category!r} needs tests")
        for node_id in tests:
            if not isinstance(node_id, str) or "::" not in node_id or "[" in node_id:
                raise pytest.UsageError(f"{path}: invalid test node ID {node_id!r}")
            if node_id in selected:
                raise pytest.UsageError(f"{path}: test {node_id!r} is gated twice")
            selected[node_id] = (category, reason.strip())
    return selected


# Run before `-k`/`-m` deselection so the stale check sees every collected test.
@pytest.hookimpl(tryfirst=True)
def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    gates_path = os.environ.get(GATES_ENV)
    if not gates_path:
        return
    gates = load_gates(Path(gates_path))
    matched: set[str] = set()
    for item in items:
        node_id = item.nodeid.split("[", 1)[0]
        gate = gates.get(node_id)
        if gate is None:
            continue
        category, reason = gate
        matched.add(node_id)
        item.add_marker(pytest.mark.skip(reason=f"ODH gate [{category}]: {reason}"))

    # Only a full collection can prove a gate stale; the runner enables strict
    # mode because it always collects all of e2e/python.
    stale = sorted(gates.keys() - matched)
    if stale and os.environ.get(STRICT_ENV) == "1":
        raise pytest.UsageError(
            f"{gates_path}: gated tests were not collected: {', '.join(stale)}"
        )
