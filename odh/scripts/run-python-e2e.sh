#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Run the supported upstream Python gateway E2E suite and post-process its
# JUnit report. Invoked by e2e-odh-entrypoint.sh through run_child, which
# exec's this script into its own session — a shell function cannot be
# exec'd, so the runner lives here as an executable like the nextest and
# merge helpers.
#
# Environment contract with the entrypoint:
#   OPENSHELL_E2E_DEPLOY_GATEWAY  0 in no-deploy mode (drives the endpoint
#                                 override rejection below)
#   OPENSHELL_E2E_PYTEST_PYTHON_FILES  the python_files pattern shared with
#                                 the entrypoint's strict gate check
#   E2E_PARALLEL                  xdist worker count
#   OPENSHELL_E2E_PYTHON          optional interpreter override
#   UV_PROJECT_ENVIRONMENT        optional uv project environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/python-e2e-common.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"
mode="${1:-}"

# A leftover endpoint override would split a no-deploy run: the SDK
# session fixtures resolve the gateway from metadata.json while
# test_security_tls.py honors the override, so one pytest run can talk
# to two different gateways. The deploy branch unsets it; reject it
# here because no-deploy has no gateway to re-point.
if [[ "${mode}" != "--collect-only" && "${OPENSHELL_E2E_DEPLOY_GATEWAY:-1}" == 0 && -n "${OPENSHELL_GATEWAY_ENDPOINT:-}" ]]; then
	echo "ERROR: OPENSHELL_GATEWAY_ENDPOINT is set, but no-deploy mode has no gateway to re-point: unset it before running the Python suite" >&2
	exit 2
fi
python_test_bin="$(resolve_python_test_bin "${ROOT}")" || exit 2

prepare_python_e2e_environment "${ROOT}" "${SCRIPT_DIR}"
pytest_args=(
	-p no:cacheprovider
	-p pytest_odh_gates
	-o "python_files=${OPENSHELL_E2E_PYTEST_PYTHON_FILES:-test_*.py *_test.py}"
	-m "not gpu"
	e2e/python
)
if [[ "${mode}" == "--collect-only" ]]; then
	if [[ $# -ne 1 ]]; then
		echo "Usage: $0 <report.xml>|--collect-only" >&2
		exit 2
	fi
	echo "==> Collecting ODH Python gateway E2E gates"
	collect_status=0
	collect_output="$(cd "${ROOT}" && "${python_test_bin}" -m pytest "${pytest_args[@]}" -p no:xdist --collect-only -q 2>&1)" || collect_status=$?
	if [[ "${collect_status}" != 0 ]]; then
		printf '%s\n' "${collect_output}" >&2
	fi
	exit "${collect_status}"
fi
if [[ -z "${mode}" || $# -ne 1 ]]; then
	echo "Usage: $0 <report.xml>|--collect-only" >&2
	exit 2
fi
report="${mode}"
[[ "${report}" == /* ]] || report="${ROOT}/${report}"
status=0
echo "==> Running ODH Python gateway E2E"
(cd "${ROOT}" && OPENSHELL_E2E_OIDC=0 \
	"${python_test_bin}" -m pytest "${pytest_args[@]}" -n "${E2E_PARALLEL:-5}" \
	--junitxml "${report}") || status=$?

# Strip skipped testcases from the JUnit report and require at least one
# executed case in the same pass: DevTestOps CI parses the XML and would
# create a Jira for every skipped case, and this lane intentionally skips
# a sizeable share of its collected cases through gates, so an upstream
# or environment change that skips the remaining supported tests must
# fail the phase instead of reporting a vacuous pass. The helper also
# recomputes the suite attributes so the merged report stays
# self-consistent.
if [[ -f "${report}" ]]; then
	strip_status=0
	"${python_test_bin}" "${SCRIPT_DIR}/strip-skipped-testcases.py" "${report}" || strip_status=$?
	case "${strip_status}" in
		0) ;;
		1)
			if [[ "${status}" == 0 ]]; then
				echo "ERROR: Python gateway E2E executed no test cases (every collected case was skipped)" >&2
				status=1
			fi
			;;
		*)
		echo "ERROR: failed to post-process JUnit report ${report} (${strip_status})" >&2
		[[ "${status}" != 0 ]] || status="${strip_status}"
			;;
	esac
fi
if [[ "${status}" == 5 ]]; then
	echo "ERROR: Python gateway E2E selected no tests" >&2
fi
if [[ ! -f "${report}" ]]; then
	echo "ERROR: Python gateway E2E did not write a JUnit report" >&2
	[[ "${status}" != 0 ]] || status=1
fi
exit "${status}"
