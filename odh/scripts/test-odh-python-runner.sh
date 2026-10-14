#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Exercise the ODH Python runner contract without a cluster: argument and
# preflight validation, distinct report names, failure propagation, rejection
# of empty selections and missing reports, and signal forwarding to pytest.
# A stub interpreter stands in for `python -m pytest`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="${ROOT}/odh/scripts/run-odh-python-tests.sh"
WORKDIR="$(mktemp -d)"
STUB="${WORKDIR}/python"
RESULTS="${WORKDIR}/results"
failures=0

cleanup() {
	rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# The stub records its arguments, writes the --junitxml report unless told not
# to, and exits with ODH_STUB_STATUS. ODH_STUB_SLEEP keeps it running so the
# test can signal the runner; the stub records the signal it receives.
cat > "${STUB}" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" --collect-only "* ]]; then
	printf "%s\n" "$*" > "${ODH_STUB_PREFLIGHT_LOG}"
	if [[ -n "${ODH_STUB_PREFLIGHT_STATUS:-}" ]]; then
		echo "ERROR: gates.toml: gated tests were not collected: e2e/python/test_x.py::test_gone"
		exit "${ODH_STUB_PREFLIGHT_STATUS}"
	fi
	exit 0
fi
printf "%s\n" "$*" > "${ODH_STUB_LOG}"
report=""
while (($#)); do [[ "$1" == --junitxml ]] && report="$2"; shift; done
if [[ -n "${report}" && "${ODH_STUB_NO_REPORT:-0}" != 1 ]]; then
	printf '<testsuites><testsuite name="stub" tests="1"/></testsuites>\n' > "${report}"
fi
if [[ -n "${ODH_STUB_SLEEP:-}" ]]; then
	trap 'echo TERM > "${ODH_STUB_SIGNAL_LOG}"; exit 143' TERM
	: > "${ODH_STUB_READY}"
	sleep "${ODH_STUB_SLEEP}" & wait $!
fi
exit "${ODH_STUB_STATUS:-0}"
STUB
chmod +x "${STUB}"

export OPENSHELL_E2E_PYTHON="${STUB}"
export OPENSHELL_E2E_RESULTS_DIR="${RESULTS}"
export ODH_STUB_LOG="${WORKDIR}/stub.log"
export ODH_STUB_PREFLIGHT_LOG="${WORKDIR}/preflight.log"
export ODH_STUB_SIGNAL_LOG="${WORKDIR}/signal.log"
export ODH_STUB_READY="${WORKDIR}/ready"
export XDG_CONFIG_HOME="${WORKDIR}/config"
unset OPENSHELL_GATEWAY

fail() {
	echo "FAIL: $*" >&2
	failures=$((failures + 1))
}

# expect_status <expected> <description> <runner args...>
expect_status() {
	local expected="$1" description="$2" status=0
	shift 2
	"${RUNNER}" "$@" > "${WORKDIR}/out.log" 2>&1 || status=$?
	if [[ "${status}" != "${expected}" ]]; then
		fail "${description}: expected exit ${expected}, got ${status}"
		sed 's/^/    /' "${WORKDIR}/out.log" >&2
	fi
}

expect_status 2 "missing mode"
expect_status 2 "extra argument" sdk extra
expect_status 2 "unknown mode" unit
OPENSHELL_E2E_PYTHON="${WORKDIR}/missing" expect_status 2 "missing interpreter" sdk
expect_status 2 "gateway-e2e without a selected gateway" gateway-e2e
[[ ! -f "${ODH_STUB_PREFLIGHT_LOG}" ]] || fail "gate preflight must not run without a gateway"

expect_status 0 "sdk success" sdk
[[ -f "${RESULTS}/e2e-odh-python-sdk.xml" ]] || fail "sdk report name"
grep -q -- "-m not gpu .*${ROOT}/python/openshell --junitxml" "${ODH_STUB_LOG}" || fail "sdk selection"
grep -q -- "--ignore ${ROOT}/python/openshell/release_formula_test.py" "${ODH_STUB_LOG}" || fail "sdk packaging exclusion"
if grep -q -- "pytest_odh_gates" "${ODH_STUB_LOG}"; then
	fail "sdk mode must not load the gateway gates"
fi

OPENSHELL_GATEWAY=openshift-test expect_status 0 "gateway-e2e with OPENSHELL_GATEWAY" gateway-e2e
[[ -f "${RESULTS}/e2e-odh-python-gateway-e2e.xml" ]] || fail "gateway-e2e report name"
grep -q -- "-p pytest_odh_gates" "${ODH_STUB_LOG}" || fail "gateway-e2e gates plugin"
grep -q -- "-n 5 ${ROOT}/e2e/python" "${ODH_STUB_LOG}" || fail "gateway-e2e selection"
grep -q -- "-p no:xdist -p pytest_odh_gates" "${ODH_STUB_PREFLIGHT_LOG}" || fail "gateway-e2e serial gate preflight"

# A stale gate fails before any test runs, with the reason on stderr.
rm -f "${ODH_STUB_LOG}"
OPENSHELL_GATEWAY=openshift-test ODH_STUB_PREFLIGHT_STATUS=4 expect_status 2 "stale gate preflight" gateway-e2e
grep -q "gated tests were not collected" "${WORKDIR}/out.log" || fail "stale gate reason"
[[ ! -f "${ODH_STUB_LOG}" ]] || fail "tests must not run after a failed gate preflight"

mkdir -p "${XDG_CONFIG_HOME}/openshell"
printf 'openshift-test\n' > "${XDG_CONFIG_HOME}/openshell/active_gateway"
expect_status 0 "gateway-e2e with an active gateway file" gateway-e2e
rm -f "${XDG_CONFIG_HOME}/openshell/active_gateway"

ODH_STUB_STATUS=1 expect_status 1 "test failure propagates" sdk
[[ -f "${RESULTS}/e2e-odh-python-sdk.xml" ]] || fail "failed run keeps its report"

ODH_STUB_STATUS=5 expect_status 5 "empty selection fails" sdk
grep -q "selected no tests" "${WORKDIR}/out.log" || fail "empty selection message"

ODH_STUB_NO_REPORT=1 expect_status 1 "missing JUnit report fails" sdk

# Signal forwarding: TERM to the runner must reach pytest and exit 143.
rm -f "${ODH_STUB_READY}" "${ODH_STUB_SIGNAL_LOG}"
ODH_STUB_SLEEP=30 "${RUNNER}" sdk > "${WORKDIR}/out.log" 2>&1 &
runner_pid=$!
for _ in $(seq 1 100); do
	[[ -f "${ODH_STUB_READY}" ]] && break
	sleep 0.1
done
kill -TERM "${runner_pid}"
status=0
wait "${runner_pid}" || status=$?
[[ "${status}" == 143 ]] || fail "TERM exit status: expected 143, got ${status}"
grep -qx TERM "${ODH_STUB_SIGNAL_LOG}" 2>/dev/null || fail "TERM was not forwarded to pytest"

if [[ "${failures}" != 0 ]]; then
	echo "${failures} ODH Python runner check(s) failed" >&2
	exit 1
fi
echo "ODH Python runner checks passed"
