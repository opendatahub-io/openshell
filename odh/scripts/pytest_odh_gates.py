# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Apply explicit, validated OpenShift capability gates to upstream pytest E2E."""

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
    with path.open("rb") as stream:
        gates = tomllib.load(stream).get("gate", [])
    if not isinstance(gates, list):
        raise pytest.UsageError(f"{path}: 'gate' must be an array of tables")
    selected: dict[str, tuple[str, str]] = {}
    for gate in gates:
        if not isinstance(gate, dict):
            raise pytest.UsageError(f"{path}: each gate must be a table")
        category, reason, tests = (
            gate.get("category"),
            gate.get("reason"),
            gate.get("tests"),
        )
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


@pytest.hookimpl(tryfirst=True)
def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    gates_path = os.environ.get(GATES_ENV)
    if not gates_path:
        return
    gates = load_gates(Path(gates_path))
    matched: set[str] = set()
    for item in items:
        node_id = item.nodeid.split("[", 1)[0]
        if gate := gates.get(node_id):
            category, reason = gate
            matched.add(node_id)
            item.add_marker(pytest.mark.skip(reason=f"ODH gate [{category}]: {reason}"))
    stale = sorted(gates.keys() - matched)
    if stale and os.environ.get(STRICT_ENV) == "1":
        raise pytest.UsageError(f"{gates_path}: gated tests were not collected: {', '.join(stale)}")
