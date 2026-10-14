# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Tests for the ODH Python gate plugin. Run with ``-p pytester``."""

from __future__ import annotations

import pytest

pytest_plugins = ["pytester"]

_TESTS = """
import pytest

def test_supported():
    pass

def test_needs_egress():
    pass

@pytest.mark.parametrize("case", ["a", "b"])
def test_parametrized(case):
    pass
"""


@pytest.fixture
def run(pytester: pytest.Pytester, monkeypatch: pytest.MonkeyPatch):
    pytester.makepyfile(test_sample=_TESTS)

    def _run(body: str, *args: str, strict: bool = False) -> pytest.RunResult:
        gates = pytester.makefile(".toml", gates=body)
        monkeypatch.setenv("OPENSHELL_ODH_PYTHON_GATES", str(gates))
        if strict:
            monkeypatch.setenv("OPENSHELL_ODH_PYTHON_GATES_STRICT", "1")
        else:
            monkeypatch.delenv("OPENSHELL_ODH_PYTHON_GATES_STRICT", raising=False)
        return pytester.runpytest("-p", "pytest_odh_gates", "-rs", *args)

    return _run


def test_gated_tests_skip_with_category_and_reason(run) -> None:
    result = run(
        """
[[gate]]
category = "egress"
reason = "no internet"
tests = ["test_sample.py::test_needs_egress", "test_sample.py::test_parametrized"]
""",
        strict=True,
    )
    result.assert_outcomes(passed=1, skipped=3)
    result.stdout.fnmatch_lines(["*ODH gate [[]egress[]]: no internet*"])


def test_without_gate_file_plugin_is_inactive(
    pytester: pytest.Pytester, monkeypatch
) -> None:
    pytester.makepyfile(test_sample=_TESTS)
    monkeypatch.delenv("OPENSHELL_ODH_PYTHON_GATES", raising=False)
    pytester.runpytest("-p", "pytest_odh_gates").assert_outcomes(passed=4)


def test_strict_mode_rejects_stale_gate(run) -> None:
    result = run(
        """
[[gate]]
category = "egress"
reason = "no internet"
tests = ["test_sample.py::test_removed_upstream"]
""",
        strict=True,
    )
    assert result.ret == pytest.ExitCode.USAGE_ERROR
    result.stderr.fnmatch_lines(
        ["*gated tests were not collected: test_sample.py::test_removed_upstream*"]
    )


def test_narrowed_run_tolerates_unselected_gates_without_strict(run) -> None:
    result = run(
        """
[[gate]]
category = "egress"
reason = "no internet"
tests = ["test_sample.py::test_needs_egress"]
""",
        "test_sample.py::test_supported",
    )
    result.assert_outcomes(passed=1)


def test_strict_mode_tolerates_k_deselection(run) -> None:
    result = run(
        """
[[gate]]
category = "egress"
reason = "no internet"
tests = ["test_sample.py::test_needs_egress"]
""",
        "-k",
        "supported",
        strict=True,
    )
    result.assert_outcomes(passed=1)


@pytest.mark.parametrize(
    ("body", "message"),
    [
        ('gate = "x"', "'gate' must be an array of tables"),
        (
            '[[gate]]\ncategory = "Bad Category"\nreason = "r"\ntests = ["t.py::a"]',
            "invalid gate category",
        ),
        (
            '[[gate]]\ncategory = "egress"\nreason = " "\ntests = ["t.py::a"]',
            "needs a reason",
        ),
        ('[[gate]]\ncategory = "egress"\nreason = "r"\ntests = []', "needs tests"),
        (
            '[[gate]]\ncategory = "egress"\nreason = "r"\ntests = ["t.py::a[x]"]',
            "invalid test node ID",
        ),
        (
            '[[gate]]\ncategory = "egress"\nreason = "r"\ntests = ["t.py::a"]\n'
            '[[gate]]\ncategory = "kernel"\nreason = "r"\ntests = ["t.py::a"]',
            "is gated twice",
        ),
    ],
)
def test_invalid_gate_files_are_rejected(run, body: str, message: str) -> None:
    result = run(body)
    assert result.ret == pytest.ExitCode.USAGE_ERROR
    result.stderr.fnmatch_lines([f"*{message}*"])
