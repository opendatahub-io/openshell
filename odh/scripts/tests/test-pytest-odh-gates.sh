#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Exercise the pytest_odh_gates plugin's gates-loading error handling: a
# missing or malformed gates file must surface as a clean pytest UsageError
# naming the file, not as a pytest INTERNALERROR with a raw traceback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PLUGIN_DIR="${ROOT}/odh/scripts"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# Resolve an interpreter that has pytest available: the plugin imports it.
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3)}"
if ! "${PYTHON_BIN}" -c 'import pytest' >/dev/null 2>&1; then
	if [[ -x "${ROOT}/.venv/bin/python" ]]; then
		PYTHON_BIN="${ROOT}/.venv/bin/python"
	else
		echo "SKIP: no python with pytest available (PYTHON_BIN=${PYTHON_BIN})" >&2
		exit 0
	fi
fi

mkdir -p "${WORKDIR}/case"
cat > "${WORKDIR}/case/test_dummy.py" <<'PY'
def test_dummy():
    pass
PY

run_gates() {
	local gates_path="$1" strict="$2"
	(
		cd "${WORKDIR}/case"
		PYTHONPATH="${PLUGIN_DIR}:${ROOT}/python" \
		OPENSHELL_ODH_PYTHON_GATES="${gates_path}" \
		OPENSHELL_ODH_PYTHON_GATES_STRICT="${strict}" \
		"${PYTHON_BIN}" -m pytest -p pytest_odh_gates -q test_dummy.py 2>&1
	)
}

expect_usage_error() {
	local label="$1" gates_path="$2" expected="$3" output status
	if output="$(run_gates "${gates_path}" 1)"; then
		status=0
	else
		status=$?
	fi
	if [[ "${status}" == 0 ]]; then
		echo "FAIL: ${label} passed, expected a pytest UsageError" >&2
		return 1
	fi
	if grep -q "INTERNALERROR" <<<"${output}"; then
		echo "FAIL: ${label} surfaced as a pytest INTERNALERROR instead of a UsageError" >&2
		return 1
	fi
	grep -q -- "${expected}" <<<"${output}" || {
		echo "FAIL: ${label} did not report the gates load failure clearly" >&2
		printf '%s\n' "${output}" >&2
		return 1
	}
	echo "ok: ${label} reports a clean UsageError"
}

expect_usage_error "missing gates file" "${WORKDIR}/does-not-exist.toml" "cannot load gates"

printf 'this is [ not toml' > "${WORKDIR}/malformed.toml"
expect_usage_error "malformed gates TOML" "${WORKDIR}/malformed.toml" "cannot load gates"

printf '[wrong]\n' > "${WORKDIR}/missing-gate.toml"
expect_usage_error "missing gate key" "${WORKDIR}/missing-gate.toml" "missing required 'gate'"

# Control: a valid gates file loads and the run still passes with the gate
# applied as a skip (no strict mode, so an unmatched gate is not an error).
cat > "${WORKDIR}/valid.toml" <<'TOML'
[[gate]]
category = "control"
reason = "verify gates load"
tests = ["test_dummy.py::test_dummy"]
TOML
if ! run_gates "${WORKDIR}/valid.toml" 0 > "${WORKDIR}/control.log" 2>&1; then
	echo "FAIL: valid gates file failed the control run:" >&2
	cat "${WORKDIR}/control.log" >&2
	exit 1
fi
grep -q "1 skipped" "${WORKDIR}/control.log" || {
	echo "FAIL: control gate did not skip the matching test:" >&2
	cat "${WORKDIR}/control.log" >&2
	exit 1
}

echo "pytest_odh_gates error handling checks passed"
