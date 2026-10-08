#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Run one Python test mode for the ODH e2e image. `sdk` runs the Python SDK
# unit tests and needs no cluster. `gateway-e2e` runs e2e/python against an
# already deployed and selected gateway; it never deploys or tears down. Each
# mode writes its own JUnit XML report with an HTML companion.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GATES_FILE="${ROOT}/odh/python-gates.toml"
MODE="${1:-}"

if [[ -z "${MODE}" || $# -ne 1 ]]; then
	echo "Usage: $0 <sdk|gateway-e2e>" >&2
	exit 2
fi

# Prefer an explicit interpreter, then the image venv, then a local uv venv.
python_bin="${OPENSHELL_E2E_PYTHON:-}"
if [[ -z "${python_bin}" && -n "${UV_PROJECT_ENVIRONMENT:-}" ]]; then
	python_bin="${UV_PROJECT_ENVIRONMENT}/bin/python"
fi
if [[ -z "${python_bin}" ]]; then
	python_bin="${ROOT}/.venv/bin/python"
fi
if [[ ! -x "${python_bin}" ]]; then
	echo "ERROR: Python test interpreter not found at ${python_bin}; run 'uv sync' or set OPENSHELL_E2E_PYTHON" >&2
	exit 2
fi

pytest_args=(-p no:cacheprovider)
case "${MODE}" in
	sdk)
		# These tests check packaging and local gateway fixtures, not the SDK,
		# and read repository files that the e2e image does not carry.
		pytest_args+=(
			-m "not gpu"
			--ignore "${ROOT}/python/openshell/release_formula_test.py"
			--ignore "${ROOT}/python/openshell/rpm_gateway_config_migration_test.py"
			--ignore "${ROOT}/python/openshell/gateway_config_fixture_test.py"
			"${ROOT}/python/openshell"
		)
		;;
	gateway-e2e)
		# Tests resolve the gateway the same way the CLI does.
		active_gateway="${XDG_CONFIG_HOME:-${HOME}/.config}/openshell/active_gateway"
		if [[ -z "${OPENSHELL_GATEWAY:-}" && ! -s "${active_gateway}" ]]; then
			echo "ERROR: no gateway selected; set OPENSHELL_GATEWAY or select one with 'openshell gateway select'" >&2
			exit 2
		fi
		export OPENSHELL_ODH_PYTHON_GATES="${GATES_FILE}"
		pytest_args+=(
			-p pytest_odh_gates
			-o "python_files=test_*.py *_test.py"
			-m "not gpu"
			-n "${E2E_PARALLEL:-5}"
			"${ROOT}/e2e/python"
		)
		gates_preflight=1
		;;
	*)
		echo "ERROR: unknown Python test mode: ${MODE}" >&2
		exit 2
		;;
esac

results_dir="${OPENSHELL_E2E_RESULTS_DIR:-${ROOT}/results}"
mkdir -p "${results_dir}"
name="e2e-odh-python-${MODE}"
report="${results_dir}/${name}.xml"
rm -f "${report}" "${report%.xml}.html"

export UV_NO_SYNC=1
export PYTHONPATH="${ROOT}/python:${SCRIPT_DIR}${PYTHONPATH:+:${PYTHONPATH}}"

# xdist workers cannot report a stale gate cleanly, so validate the gate list
# with a serial, collection-only pass before running any test.
if [[ "${gates_preflight:-0}" == 1 ]]; then
	if ! preflight="$(cd "${ROOT}" && OPENSHELL_ODH_PYTHON_GATES_STRICT=1 \
		"${python_bin}" -m pytest -p no:cacheprovider -p no:xdist -p pytest_odh_gates \
		-o "python_files=test_*.py *_test.py" --collect-only -q "${ROOT}/e2e/python" 2>&1)"; then
		echo "ERROR: Python gate preflight failed" >&2
		printf '%s\n' "${preflight}" | grep -E '^(ERROR|E )' >&2 || printf '%s\n' "${preflight}" | tail -20 >&2
		exit 2
	fi
fi

echo "==> Running ODH Python mode ${MODE}"
status=0
pytest_pid=""
stop_pytest() {
	local signal="$1" code="$2"
	trap '' INT TERM
	if [[ -n "${pytest_pid}" ]]; then
		kill -"${signal}" "${pytest_pid}" 2>/dev/null || true
		wait "${pytest_pid}" || true
	fi
	exit "${code}"
}
trap 'stop_pytest TERM 130' INT
trap 'stop_pytest TERM 143' TERM
(cd "${ROOT}" && exec "${python_bin}" -m pytest "${pytest_args[@]}" --junitxml "${report}") &
pytest_pid=$!
wait "${pytest_pid}" || status=$?
pytest_pid=""
trap - INT TERM

# pytest exits 5 when it collects no tests; an empty mode must not pass.
if [[ "${status}" == 5 ]]; then
	echo "ERROR: Python mode ${MODE} selected no tests" >&2
fi

if [[ -f "${report}" ]]; then
	echo "JUnit report: ${report}"
	if command -v xsltproc >/dev/null 2>&1; then
		xsltproc --stringparam title "${name}" \
			"${ROOT}/scripts/junit-to-html.xsl" "${report}" \
			> "${report%.xml}.html" \
			|| echo "WARNING: failed to render HTML report" >&2
	else
		echo "WARNING: xsltproc not found; HTML report unavailable" >&2
	fi
else
	echo "ERROR: pytest did not write a JUnit report" >&2
	[[ "${status}" != 0 ]] || status=1
fi

exit "${status}"
