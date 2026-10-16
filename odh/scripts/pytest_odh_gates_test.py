# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Minimal regression coverage for the downstream pytest gate plugin."""

from __future__ import annotations

import pytest

pytest_plugins = ["pytester"]


@pytest.fixture
def run(pytester: pytest.Pytester, monkeypatch: pytest.MonkeyPatch):
    pytester.makepyfile(
        test_sample="""
import pytest

def test_supported():
    pass

@pytest.mark.parametrize("case", ["a", "b"])
def test_requires_egress(case):
    pass
"""
    )

    def _run(gates: str, *, strict: bool = False) -> pytest.RunResult:
        gates_file = pytester.makefile(".toml", gates=gates)
        monkeypatch.setenv("OPENSHELL_ODH_PYTHON_GATES", str(gates_file))
        if strict:
            monkeypatch.setenv("OPENSHELL_ODH_PYTHON_GATES_STRICT", "1")
        else:
            monkeypatch.delenv("OPENSHELL_ODH_PYTHON_GATES_STRICT", raising=False)
        return pytester.runpytest("-p", "pytest_odh_gates", "-rs")

    return _run


def test_gate_skips_every_parameterization_with_its_reason(run) -> None:
    result = run(
        """
[[gate]]
category = "egress"
reason = "no internet"
tests = ["test_sample.py::test_requires_egress"]
""",
        strict=True,
    )

    result.assert_outcomes(passed=1, skipped=2)
    result.stdout.fnmatch_lines(["*ODH gate [[]egress[]]: no internet*"])


def test_strict_mode_rejects_a_gate_for_a_removed_test(run) -> None:
    result = run(
        """
[[gate]]
category = "egress"
reason = "no internet"
tests = ["test_sample.py::test_removed"]
""",
        strict=True,
    )

    assert result.ret == pytest.ExitCode.USAGE_ERROR
    result.stderr.fnmatch_lines(
        ["*gated tests were not collected: test_sample.py::test_removed*"]
    )


def test_invalid_gate_configuration_is_rejected(run) -> None:
    result = run('gate = "not-an-array"')

    assert result.ret == pytest.ExitCode.USAGE_ERROR
    result.stderr.fnmatch_lines(["*'gate' must be an array of tables*"])
