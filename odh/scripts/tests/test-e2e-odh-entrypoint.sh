#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# A deployment failure before the Python runner must not leave an old Python
# report to be picked up as raw evidence by a later invocation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENTRYPOINT="${SCRIPT_DIR}/../e2e-odh-entrypoint.sh"

WORKDIR="$(mktemp -d)"
RELATIVE_REPORT_DIR=""
RELATIVE_REPORT_DIR_CREATED=0
cleanup() {
	rm -rf "${WORKDIR}"
	if [[ "${RELATIVE_REPORT_DIR_CREATED}" == 1 ]]; then
		rmdir -- "${RELATIVE_REPORT_DIR}" 2>/dev/null || true
	fi
}
trap cleanup EXIT
RESULTS_DIR="${WORKDIR}/results"
STALE_PYTHON_REPORT="${RESULTS_DIR}/e2e-odh-python-shared-python.xml"
MERGED_REPORT="${RESULTS_DIR}/e2e-odh-python-xunit.xml"
KUBECONFIG_FILE="${WORKDIR}/kubeconfig"
DEPLOY_SCRIPT="${WORKDIR}/fail-deploy.sh"
LOG_FILE="${WORKDIR}/entrypoint.log"
BIN_DIR="${WORKDIR}/bin"

mkdir -p "${RESULTS_DIR}"
printf '<testsuites/>\n' > "${STALE_PYTHON_REPORT}"
printf '<testsuites/>\n' > "${MERGED_REPORT}"
printf 'apiVersion: v1\nkind: Config\n' > "${KUBECONFIG_FILE}"
printf '#!/usr/bin/env bash\nexit 1\n' > "${DEPLOY_SCRIPT}"
chmod +x "${DEPLOY_SCRIPT}"
mkdir -p "${BIN_DIR}"
printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN_DIR}/oc"
chmod +x "${BIN_DIR}/oc"

PYTHON_TEST_BIN="${PYTHON_BIN:-${ROOT}/.venv/bin/python}"
if [[ ! -x "${PYTHON_TEST_BIN}" ]]; then
	PYTHON_TEST_BIN="$(command -v python3)"
fi
if ! PYTHONPATH="${ROOT}/python:${ROOT}/odh/scripts" "${PYTHON_TEST_BIN}" -c 'import pytest, tomllib, openshell, pytest_odh_gates' >/dev/null 2>&1; then
	echo "SKIP: no Python E2E test interpreter available (PYTHON_BIN=${PYTHON_TEST_BIN})" >&2
	exit 0
fi

if KUBECONFIG="${KUBECONFIG_FILE}" \
	OPENSHELL_E2E_RESULTS_DIR="${RESULTS_DIR}" \
	OPENSHELL_E2E_DEPLOY_SCRIPT="${DEPLOY_SCRIPT}" \
	OPENSHELL_E2E_PYTHON="${PYTHON_TEST_BIN}" \
	PYTHON_BIN="${PYTHON_TEST_BIN}" \
	PATH="${BIN_DIR}:${PATH}" \
	"${ENTRYPOINT}" python > "${LOG_FILE}" 2>&1; then
	echo "FAIL: python entrypoint unexpectedly succeeded with a failing deployment" >&2
	exit 1
fi

[[ ! -e "${STALE_PYTHON_REPORT}" ]] || {
	echo "FAIL: stale Python report survived a deployment failure" >&2
	exit 1
}
[[ ! -e "${MERGED_REPORT}" ]] || {
	echo "FAIL: stale merged report survived a deployment failure" >&2
	exit 1
}
grep -q 'deployment/preflight failed for python/shared' "${LOG_FILE}" || {
	echo "FAIL: fake deployment failure was not observed" >&2
	cat "${LOG_FILE}" >&2
	exit 1
}
if grep -q 'could not list managed-workspace namespaces' "${LOG_FILE}"; then
	echo "FAIL: entrypoint fixture reached a real or missing oc binary" >&2
	cat "${LOG_FILE}" >&2
	exit 1
fi
if grep -q 'failed to merge ODH phase reports' "${LOG_FILE}"; then
	echo "FAIL: deployment failure was obscured by an empty-report merge failure" >&2
	cat "${LOG_FILE}" >&2
	exit 1
fi

echo "entrypoint clears stale Python reports before deployment"

# A runner failure must retain its original pytest exit status even if the
# resulting report happens to contain only skipped test cases. Otherwise an
# infrastructure/collection error (for example pytest's exit 2) is rewritten
# as the unrelated "every test was skipped" failure.
FAKE_PYTEST_PYTHON="${WORKDIR}/fake-pytest-python.sh"
RUNNER_REPORT="${WORKDIR}/runner.xml"
RUNNER_LOG="${WORKDIR}/runner.log"
cat > "${FAKE_PYTEST_PYTHON}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
	case "$1" in
		--junitxml)
			report="$2"
			shift 2
			;;
		*) shift ;;
	esac
done
printf '<testsuite name="python" tests="1" skipped="1" failures="0" errors="0"><testcase name="skipped"><skipped/></testcase></testsuite>\n' > "${report}"
exit 2
SH
chmod +x "${FAKE_PYTEST_PYTHON}"

if PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_PYTHON="${FAKE_PYTEST_PYTHON}" \
	"${SCRIPT_DIR}/../run-python-e2e.sh" "${RUNNER_REPORT}" > "${RUNNER_LOG}" 2>&1; then
	echo "FAIL: fake pytest failure unexpectedly succeeded" >&2
	exit 1
else
	status=$?
	[[ "${status}" == 2 ]] || {
		echo "FAIL: fake pytest failure exited ${status}, expected 2" >&2
		cat "${RUNNER_LOG}" >&2
		exit 1
	}
fi
if grep -q 'executed no test cases' "${RUNNER_LOG}"; then
	echo "FAIL: a pytest failure was misreported as an all-skipped run" >&2
	cat "${RUNNER_LOG}" >&2
	exit 1
fi
echo "entrypoint preserves a failing Python runner status"

# Collection diagnostics are normally quiet, but must remain visible when
# pytest rejects a module during preflight. Pytest sends import failures to
# stdout, so dropping only stdout makes the entrypoint's failure guidance
# misleading.
FAKE_COLLECTION_PYTHON="${WORKDIR}/fake-collection-python.sh"
COLLECTION_LOG="${WORKDIR}/collection.log"
cat > "${FAKE_COLLECTION_PYTHON}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo 'ERROR collecting e2e/python/test_broken.py'
echo 'ModuleNotFoundError: No module named broken_module'
exit 2
SH
chmod +x "${FAKE_COLLECTION_PYTHON}"
if PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_PYTHON="${FAKE_COLLECTION_PYTHON}" \
	"${SCRIPT_DIR}/../run-python-e2e.sh" --collect-only > "${COLLECTION_LOG}" 2>&1; then
	echo "FAIL: fake collection error unexpectedly succeeded" >&2
	exit 1
else
	status=$?
	[[ "${status}" == 2 ]] || {
		echo "FAIL: fake collection error exited ${status}, expected 2" >&2
		cat "${COLLECTION_LOG}" >&2
		exit 1
	}
fi
grep -q 'ERROR collecting e2e/python/test_broken.py' "${COLLECTION_LOG}" || {
	echo "FAIL: collection diagnostics were discarded" >&2
	cat "${COLLECTION_LOG}" >&2
	exit 1
}
echo "runner preserves failing collection diagnostics"

# A direct no-deploy run must reject an endpoint override before attempting to
# resolve an interpreter or collect tests: the endpoint would split the suite
# between the metadata-selected gateway and the explicitly selected endpoint.
NO_DEPLOY_LOG="${WORKDIR}/no-deploy-endpoint.log"
if OPENSHELL_E2E_DEPLOY_GATEWAY=0 \
	OPENSHELL_GATEWAY_ENDPOINT="https://example.invalid" \
	"${SCRIPT_DIR}/../run-python-e2e.sh" "${WORKDIR}/unused.xml" > "${NO_DEPLOY_LOG}" 2>&1; then
	echo "FAIL: no-deploy endpoint override unexpectedly succeeded" >&2
	exit 1
else
	status=$?
	[[ "${status}" == 2 ]] || {
		echo "FAIL: no-deploy endpoint override exited ${status}, expected 2" >&2
		cat "${NO_DEPLOY_LOG}" >&2
		exit 1
	}
fi
grep -q 'OPENSHELL_GATEWAY_ENDPOINT is set' "${NO_DEPLOY_LOG}" || {
	echo "FAIL: no-deploy endpoint override did not explain the rejection" >&2
	cat "${NO_DEPLOY_LOG}" >&2
	exit 1
}
echo "runner rejects an endpoint override in no-deploy mode"

# A nonzero, non-0 value keeps deployment enabled. The entrypoint and direct
# runner must agree so callers cannot get a contradictory endpoint rejection.
FAKE_SUCCESS_PYTHON="${WORKDIR}/fake-success-python.sh"
RELATIVE_REPORT_NAME="results/$(basename "${WORKDIR}")-relative.xml"
RELATIVE_REPORT="${ROOT}/${RELATIVE_REPORT_NAME}"
RELATIVE_REPORT_DIR="${ROOT}/results"
if [[ ! -d "${RELATIVE_REPORT_DIR}" ]]; then
	mkdir -- "${RELATIVE_REPORT_DIR}"
	RELATIVE_REPORT_DIR_CREATED=1
fi
cat > "${FAKE_SUCCESS_PYTHON}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
	case "$1" in
		--junitxml)
			printf '<testsuite name="python" tests="1"><testcase name="passes"/></testsuite>\n' > "$2"
			shift 2
			;;
		*) shift ;;
	esac
done
SH
chmod +x "${FAKE_SUCCESS_PYTHON}"
(
	cd "${WORKDIR}"
	PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_PYTHON="${FAKE_SUCCESS_PYTHON}" \
	OPENSHELL_E2E_DEPLOY_GATEWAY=false \
	OPENSHELL_GATEWAY_ENDPOINT="https://example.invalid" \
	"${SCRIPT_DIR}/../run-python-e2e.sh" "${RELATIVE_REPORT_NAME}"
)
[[ -f "${RELATIVE_REPORT}" ]] || {
	echo "FAIL: relative report path was not resolved against the repository root" >&2
	exit 1
}
rm -f "${RELATIVE_REPORT}"
echo "runner preserves deploy mode and resolves relative reports"

# Tier 2 executes shared nextest, shared Python, then managed nextest. The
# merger must receive the reports in that same order rather than grouping them
# by runner type.
ORDERED_RESULTS_DIR="${WORKDIR}/ordered-results"
ORDERED_DEPLOY="${WORKDIR}/successful-deploy.sh"
ORDERED_PHASE_RUNNER="${WORKDIR}/phase-runner.sh"
ORDERED_MERGER="${WORKDIR}/capture-merge.py"
ORDERED_ARGS="${WORKDIR}/merge-args"
ORDERED_OPENSHELL="${WORKDIR}/openshell"
cat > "${ORDERED_DEPLOY}" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "${ORDERED_PHASE_RUNNER}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '<testsuite name="nextest" tests="1"><testcase name="passes"/></testsuite>\n' > "$3"
SH
cat > "${ORDERED_OPENSHELL}" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "${ORDERED_MERGER}" <<'PY'
import os
import sys
from pathlib import Path

Path(os.environ["ORDERED_ARGS"]).write_text("\n".join(sys.argv[2:]) + "\n")
PY
chmod +x "${ORDERED_DEPLOY}" "${ORDERED_PHASE_RUNNER}" "${ORDERED_OPENSHELL}"
KUBECONFIG="${KUBECONFIG_FILE}" \
	OPENSHELL_E2E_RESULTS_DIR="${ORDERED_RESULTS_DIR}" \
	OPENSHELL_E2E_DEPLOY_SCRIPT="${ORDERED_DEPLOY}" \
	OPENSHELL_E2E_PHASE_RUNNER="${ORDERED_PHASE_RUNNER}" \
	OPENSHELL_E2E_REPORT_MERGER="${ORDERED_MERGER}" \
	OPENSHELL_E2E_PYTHON="${FAKE_SUCCESS_PYTHON}" \
	OPENSHELL_BIN="${ORDERED_OPENSHELL}" \
	ORDERED_ARGS="${ORDERED_ARGS}" \
	PYTHON_BIN="${PYTHON_TEST_BIN}" \
	PATH="${BIN_DIR}:${PATH}" \
	"${ENTRYPOINT}" tier2 > "${WORKDIR}/ordered.log" 2>&1
expected_order="${ORDERED_RESULTS_DIR}/e2e-odh-tier2-shared.xml
${ORDERED_RESULTS_DIR}/e2e-odh-tier2-shared-python.xml
${ORDERED_RESULTS_DIR}/e2e-odh-tier2-managed.xml"
[[ "$(cat "${ORDERED_ARGS}")" == "${expected_order}" ]] || {
	echo "FAIL: merger report order did not match Tier 2 execution order" >&2
	cat "${ORDERED_ARGS}" >&2
	exit 1
}
echo "entrypoint merges reports in phase execution order"

# Model cancellation during the small interval between forking the launcher
# and setsid(). The entrypoint must signal the direct child instead of waiting
# forever for a process group that has not been created yet.
SESSION_MARKER="${WORKDIR}/setsid-pending"
SESSION_PYTHON="${WORKDIR}/slow-session-python.sh"
SLOW_DEPLOY="${WORKDIR}/slow-deploy.sh"
cat > "${SESSION_PYTHON}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == '-c' && "$2" == *'os.setsid()'* ]]; then
	exec "${REAL_PYTHON}" -c 'import os, sys, time; open(os.environ["SESSION_MARKER"], "w").close(); time.sleep(2); os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "${@:3}"
fi
exec "${REAL_PYTHON}" "$@"
SH
cat > "${SLOW_DEPLOY}" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
chmod +x "${SESSION_PYTHON}" "${SLOW_DEPLOY}"

KUBECONFIG="${KUBECONFIG_FILE}" \
OPENSHELL_E2E_RESULTS_DIR="${RESULTS_DIR}" \
OPENSHELL_E2E_DEPLOY_SCRIPT="${SLOW_DEPLOY}" \
GATEWAY_IMAGE="quay.io/opendatahub/odh-openshell-gateway@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
SANDBOX_IMAGE="quay.io/opendatahub/odh-openshell-sandbox@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
SUPERVISOR_IMAGE="quay.io/opendatahub/odh-openshell-supervisor@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
PYTHON_BIN="${SESSION_PYTHON}" \
REAL_PYTHON="${PYTHON_TEST_BIN}" \
SESSION_MARKER="${SESSION_MARKER}" \
"${ENTRYPOINT}" smoke > "${WORKDIR}/cancellation.log" 2>&1 &
entrypoint_pid=$!
for _ in $(seq 1 100); do
	[[ -f "${SESSION_MARKER}" ]] && break
	sleep 0.05
done
[[ -f "${SESSION_MARKER}" ]] || {
	echo "FAIL: test launcher never reached the pre-setsid window" >&2
	kill -KILL "${entrypoint_pid}" 2>/dev/null || true
	wait "${entrypoint_pid}" 2>/dev/null || true
	exit 1
}
(
	sleep 5
	if kill -0 "${entrypoint_pid}" 2>/dev/null; then
		touch "${WORKDIR}/cancellation-timeout"
		kill -KILL "${entrypoint_pid}" 2>/dev/null || true
	fi
) &
watchdog_pid=$!
kill -TERM "${entrypoint_pid}"
wait "${entrypoint_pid}" 2>/dev/null || true
kill "${watchdog_pid}" 2>/dev/null || true
wait "${watchdog_pid}" 2>/dev/null || true
[[ ! -e "${WORKDIR}/cancellation-timeout" ]] || {
	echo "FAIL: entrypoint did not exit after cancellation before setsid" >&2
	cat "${WORKDIR}/cancellation.log" >&2
	exit 1
}
echo "entrypoint cancels a pre-setsid launcher promptly"
