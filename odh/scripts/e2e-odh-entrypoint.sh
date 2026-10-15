#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Shared local and image entrypoint for ODH tier phases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export OPENSHELL_BIN="${OPENSHELL_BIN:-${ROOT}/target/debug/openshell}"
PLAN_RESOLVER="${ROOT}/e2e/rust/tests/odh/tier_plan.py"
TIERS_FILE="${ROOT}/e2e/rust/tests/odh/tiers.toml"
DEPLOY_SCRIPT="${OPENSHELL_E2E_DEPLOY_SCRIPT:-${SCRIPT_DIR}/openshell-deploy-from-quay.sh}"
TEST_SCRIPT="${OPENSHELL_E2E_PHASE_RUNNER:-${ROOT}/e2e/rust/tests/odh/run-odh-test-tier.sh}"
MERGE_SCRIPT="${OPENSHELL_E2E_REPORT_MERGER:-${SCRIPT_DIR}/merge-e2e-odh-reports.py}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TIER="${1:-}"
if [[ -z "${TIER}" || $# -ne 1 ]]; then
	echo "Usage: $0 <smoke|tier1|tier2|tier3|odh|full|python>" >&2
	exit 2
fi

if [[ "${TIER}" == python ]]; then
	phase_lines="python|shared"
else
	plan_json="$("${PYTHON_BIN}" "${PLAN_RESOLVER}" "${TIER}" "${TIERS_FILE}")"
	phase_lines="$(printf '%s' "${plan_json}" | "${PYTHON_BIN}" -c 'import json,sys; print(chr(10).join(p["name"]+"|"+p["mode"] for p in json.load(sys.stdin)["phases"]))')"
fi
phase_count=0
while IFS= read -r _; do ((phase_count+=1)); done <<< "${phase_lines}"
deploy_enabled="${OPENSHELL_E2E_DEPLOY_GATEWAY:-1}"
if [[ "${deploy_enabled}" == 0 && "${phase_count}" -gt 1 ]]; then
	echo "ERROR: OPENSHELL_E2E_DEPLOY_GATEWAY=0 only supports single-phase tiers; this tier uses multiple gateway modes" >&2
	exit 2
fi

if [[ "${deploy_enabled}" != 0 ]]; then
	if [[ -z "${OPENSHELL_E2E_RUN_ID:-}" ]]; then
		OPENSHELL_E2E_RUN_ID="$("${PYTHON_BIN}" -c 'import secrets; print(secrets.token_hex(8))')"
	fi
	if [[ ! "${OPENSHELL_E2E_RUN_ID}" =~ ^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$ ]]; then
		echo "ERROR: OPENSHELL_E2E_RUN_ID must be 1-24 lowercase DNS-safe characters" >&2
		exit 2
	fi
	export OPENSHELL_E2E_RUN_ID
	# Temporary compatibility with upstream managed-workspace tests, which
	# currently assume the gateway namespace, release, and ID are all openshell.
	NAMESPACE="${NAMESPACE:-openshell}"
	RELEASE="${RELEASE:-openshell}"
	GATEWAY_NAME="${GATEWAY_NAME:-openshift-${OPENSHELL_E2E_RUN_ID}}"
	OPENSHELL_GATEWAY="${GATEWAY_NAME}"
	# A direct endpoint takes precedence over the selected gateway in the CLI.
	unset OPENSHELL_GATEWAY_ENDPOINT
	export NAMESPACE RELEASE GATEWAY_NAME OPENSHELL_GATEWAY

	if [[ -z "${KUBECONFIG:-}" ]]; then
		KUBECONFIG="${ROOT}/.kube/config"
		export KUBECONFIG
	fi
	if [[ ! -f "${KUBECONFIG}" ]]; then
		echo "ERROR: kubeconfig not found at ${KUBECONFIG}" >&2
		exit 1
	fi
fi

status=0
active_state=""
active_mode=""
child_pid=""
results_dir="${OPENSHELL_E2E_RESULTS_DIR:-${ROOT}/results}"
mkdir -p "${results_dir}"
results_dir="$(cd "${results_dir}" && pwd)"
export OPENSHELL_E2E_RESULTS_DIR="${results_dir}"
phase_reports=()
for phase_line in ${phase_lines}; do
	phase="${phase_line%%|*}"
	phase_report="${results_dir}/e2e-odh-${TIER}-${phase}.xml"
	phase_reports+=("${phase_report}")
	rm -f "${phase_report}" "${phase_report%.xml}.html"
done
merged_report="${results_dir}/e2e-odh-${TIER}.xml"
rm -f "${merged_report}" "${merged_report%.xml}.html"

managed_namespace_selector='openshell.ai/managed-by=openshell,openshell.ai/gateway-id=openshell'
snapshot_managed_namespaces() {
	local snapshot_file="$1"
	local temporary_file="${snapshot_file}.tmp"
	if ! oc get namespaces -l "${managed_namespace_selector}" -o name > "${temporary_file}"; then
		rm -f -- "${temporary_file}"
		return 1
	fi
	mv -- "${temporary_file}" "${snapshot_file}"
}
cleanup_managed_namespaces() {
	local state_dir="$1"
	local baseline_file="${state_dir}/managed-namespaces-before"
	local current_file="${state_dir}/managed-namespaces-current"
	local resource namespace cleanup_status=0
	[[ -f "${baseline_file}" ]] || return 0
	if ! oc get namespaces -l "${managed_namespace_selector}" -o name > "${current_file}"; then
		echo "ERROR: could not list managed-workspace namespaces for cleanup" >&2
		return 1
	fi
	while IFS= read -r resource; do
		[[ -n "${resource}" ]] || continue
		if grep -Fqx -- "${resource}" "${baseline_file}"; then
			continue
		fi
		namespace="${resource#namespace/}"
		if [[ "${namespace}" == "${resource}" || -z "${namespace}" ]]; then
			echo "ERROR: unexpected namespace resource from oc: ${resource}" >&2
			cleanup_status=1
			continue
		fi
		echo ">> Removing managed-workspace namespace '${namespace}' created during this phase"
		oc delete namespace "${namespace}" --ignore-not-found --wait=false || cleanup_status=1
	done < "${current_file}"
	return "${cleanup_status}"
}

cleanup() {
	local result=$?
	trap - EXIT
	trap '' INT TERM
	if [[ -n "${child_pid:-}" ]]; then
		# Cluster teardown must not race a live test suite: stop the child
		# tree first even when the EXIT trap fires without INT/TERM.
		stop_child_tree TERM "${child_pid}"
		wait "${child_pid}" 2>/dev/null || true
		child_pid=""
	fi
	if [[ -n "${active_state}" ]]; then
		if ! cleanup_managed_namespaces "${active_state}"; then
			echo "ERROR: managed-workspace namespace cleanup failed" >&2
			[[ "${result}" != 0 ]] || result=1
		fi
		if [[ -f "${active_state}/namespace" ]]; then
			teardown_args=(teardown --yes --mode "${active_mode}")
			if [[ ! -f "${active_state}/gateway" ]]; then teardown_args+=(--keep-local-gateway); fi
			"${DEPLOY_SCRIPT}" "${teardown_args[@]}" || {
				cleanup_status=$?
				echo "ERROR: OpenShell teardown failed (${cleanup_status})" >&2
				[[ "${result}" != 0 ]] || result="${cleanup_status}"
			}
		fi
		rm -rf "${active_state}"
	fi
	exit "${result}"
}
# Children run in their own process group (see run_child), so the
# negative-PID kill reaches the whole tree: the Python tier executes
# through a Bash wrapper whose interpreter and xdist workers are
# grandchildren that a single-PID signal never reaches. Mirrors stop_child
# in e2e/run.sh: TERM the group, wait a bounded grace period, then KILL.
stop_child_tree() {
	local signal="$1" pid="$2" _
	kill -"${signal}" -- "-${pid}" 2>/dev/null || kill -"${signal}" "${pid}" 2>/dev/null || true
	for _ in $(seq 1 30); do
		kill -0 -- "-${pid}" 2>/dev/null || return 0
		sleep 1
	done
	kill -KILL -- "-${pid}" 2>/dev/null || true
}

stop_child() {
	local signal="$1" code="$2"
	trap '' INT TERM
	if [[ -n "${child_pid}" ]]; then
		stop_child_tree "${signal}" "${child_pid}"
		wait "${child_pid}" 2>/dev/null || true
		child_pid=""
	fi
	exit "${code}"
}
run_child() {
	local result=0
	# Job control gives each background job its own process group so
	# cancellation can stop the whole process tree (see stop_child_tree).
	set -m
	"$@" &
	child_pid=$!
	set +m
	wait "${child_pid}" 2>/dev/null || result=$?
	child_pid=""
	return "${result}"
}
run_python_e2e() {
	local report="$1" python_test_bin gate_output status=0
	if [[ -n "${OPENSHELL_E2E_PYTHON:-}" ]]; then
		# An explicit interpreter override is relative to the caller.
		python_test_bin="${OPENSHELL_E2E_PYTHON}"
		if [[ "${python_test_bin}" != /* ]]; then
			python_test_bin="$(cd "$(dirname "${python_test_bin}")" && pwd -P)/$(basename "${python_test_bin}")"
		fi
	elif [[ -n "${UV_PROJECT_ENVIRONMENT:-}" ]]; then
		# uv resolves a relative project environment from the workspace root.
		python_test_bin="${UV_PROJECT_ENVIRONMENT}/bin/python"
		if [[ "${python_test_bin}" != /* ]]; then
			python_test_bin="${ROOT}/${python_test_bin}"
		fi
	else
		python_test_bin="${ROOT}/.venv/bin/python"
	fi
	if [[ ! -x "${python_test_bin}" ]]; then
		echo "ERROR: Python E2E interpreter not found at ${python_test_bin}" >&2
		return 2
	fi
	export PYTHONPATH="${ROOT}/python:${SCRIPT_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
	export OPENSHELL_ODH_PYTHON_GATES="${ROOT}/odh/python-gates.toml"
	if ! gate_output="$(cd "${ROOT}" && OPENSHELL_ODH_PYTHON_GATES_STRICT=1 \
		OPENSHELL_E2E_OIDC=0 \
		"${python_test_bin}" -m pytest -p no:cacheprovider -p no:xdist -p pytest_odh_gates \
		-o "python_files=test_*.py *_test.py" --collect-only -q e2e/python 2>&1)"; then
		echo "ERROR: Python E2E gate preflight failed" >&2
		printf '%s\n' "${gate_output}" >&2
		return 2
	fi
	echo "==> Running ODH Python gateway E2E"
	(cd "${ROOT}" && OPENSHELL_E2E_OIDC=0 \
		"${python_test_bin}" -m pytest -p no:cacheprovider -p pytest_odh_gates \
		-o "python_files=test_*.py *_test.py" -m "not gpu" -n "${E2E_PARALLEL:-5}" \
		e2e/python --junitxml "${report}") || status=$?
	# Strip skipped testcases from the JUnit report: DevTestOps CI parses
	# the XML and would create a Jira for every skipped case. The skip
	# count is preserved in the testsuite attributes for auditability.
	if [[ -f "${report}" ]]; then
		if ! "${PYTHON_BIN}" -c '
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")
for suite in suites:
    for case in list(suite.findall("testcase")):
        if case.find("skipped") is not None:
            suite.remove(case)
tree.write(path, encoding="utf-8", xml_declaration=True)
' "${report}"; then
			echo "ERROR: failed to strip skipped testcases from JUnit report ${report} (malformed?)" >&2
			[[ "${status}" != 0 ]] || status=1
		fi
	fi
	if [[ "${status}" == 5 ]]; then
		echo "ERROR: Python gateway E2E selected no tests" >&2
	fi
	if [[ ! -f "${report}" ]]; then
		echo "ERROR: Python gateway E2E did not write a JUnit report" >&2
		[[ "${status}" != 0 ]] || status=1
	fi
	if [[ "${status}" == 0 ]]; then
		# Pytest exits 0 and writes JUnit even when every collected case is
		# skipped, and this lane intentionally skips a sizeable share of its
		# collected cases through gates: an upstream or environment change
		# that skips the remaining supported tests must fail the phase
		# instead of reporting success with no gateway behavior exercised.
		# Require at least one executed (non-skipped) case.
		if ! "${PYTHON_BIN}" -c '
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")
executed = sum(
    int(s.get("tests", 0)) - int(s.get("skipped", 0)) for s in suites
)
sys.exit(0 if executed > 0 else 1)
' "${report}"; then
			echo "ERROR: Python gateway E2E executed no test cases (every collected case was skipped)" >&2
			status=1
		fi
	fi
	return "${status}"
}
trap cleanup EXIT
trap 'stop_child TERM 130' INT
trap 'stop_child TERM 143' TERM
phase_index=0
for phase_line in ${phase_lines}; do
	phase="${phase_line%%|*}"
	mode="${phase_line#*|}"
	phase_report="${phase_reports[phase_index]}"
	phase_deploy_status=0
	phase_test_status=0
	phase_managed_cleanup_status=0
	teardown_failed=0
	if [[ "${deploy_enabled}" != 0 ]]; then
		active_state="$(mktemp -d)"
		active_mode="${mode}"
		export OPENSHELL_E2E_DEPLOY_STATE_DIR="${active_state}"
		deploy_args=(deploy --yes --mode "${mode}")
		if [[ "${OPENSHELL_E2E_REPLACE_EXISTING:-0}" == 1 ]]; then deploy_args+=(--replace-existing); fi
		run_child "${DEPLOY_SCRIPT}" "${deploy_args[@]}" || phase_deploy_status=$?
		if [[ "${phase_deploy_status}" == 0 ]]; then
			run_child "${OPENSHELL_BIN:-openshell}" provider profile import --from "${ROOT}/providers" --global || phase_deploy_status=$?
		fi
	fi
	if [[ "${phase_deploy_status}" == 0 ]]; then
		if [[ -n "${active_state}" && "${mode}" == managed ]]; then
			if ! snapshot_managed_namespaces "${active_state}/managed-namespaces-before"; then
				echo "ERROR: could not snapshot managed-workspace namespaces before ${TIER}/${phase}" >&2
				phase_test_status=1
			fi
		fi
		if [[ "${phase_test_status}" == 0 ]]; then
			if [[ "${TIER}" == python ]]; then
				run_child run_python_e2e "${phase_report}" || phase_test_status=$?
			else
				run_child "${TEST_SCRIPT}" "${TIER}" "${phase}" "${phase_report}" || phase_test_status=$?
				# Python gateway tests ride tier2's shared deployment: the
				# DevTestOps CI only runs smoke through tier3, so the Python
				# lane would never execute unless it shares a tier.
				if [[ "${TIER}" == tier2 && "${phase}" == shared ]]; then
					python_report="${results_dir}/e2e-odh-${TIER}-python.xml"
					rm -f "${python_report}"
					run_child run_python_e2e "${python_report}" || phase_test_status=$?
					# The merge skips missing reports, so include it even
					# on failure to surface what ran.
					phase_reports+=("${python_report}")
				fi
			fi
		fi
	else
		echo "ERROR: deployment/preflight failed for ${TIER}/${phase} (${phase_deploy_status})" >&2
	fi
	if [[ -n "${active_state}" ]]; then
		if ! cleanup_managed_namespaces "${active_state}"; then
			echo "ERROR: managed-workspace namespace cleanup failed for ${TIER}/${phase}" >&2
			phase_managed_cleanup_status=1
		fi
		if [[ -f "${active_state}/namespace" ]]; then
			teardown_args=(teardown --yes --mode "${mode}")
			if [[ ! -f "${active_state}/gateway" ]]; then teardown_args+=(--keep-local-gateway); fi
			run_child "${DEPLOY_SCRIPT}" "${teardown_args[@]}" || {
				teardown_status=$?
				echo "ERROR: teardown failed for ${TIER}/${phase} (${teardown_status})" >&2
				[[ "${phase_deploy_status}" != 0 ]] || phase_deploy_status="${teardown_status}"
				teardown_failed=1
			}
		fi
		if [[ "${teardown_failed}" != 1 ]]; then
			rm -rf "${active_state}"
			active_state=""
			active_mode=""
			unset OPENSHELL_E2E_DEPLOY_STATE_DIR
		fi
	fi
	if [[ "${status}" == 0 && "${phase_deploy_status}" != 0 ]]; then status="${phase_deploy_status}"; fi
	if [[ "${status}" == 0 && "${phase_test_status}" != 0 ]]; then status="${phase_test_status}"; fi
	if [[ "${status}" == 0 && "${phase_managed_cleanup_status}" != 0 ]]; then status="${phase_managed_cleanup_status}"; fi
	if [[ "${teardown_failed}" == 1 ]]; then break; fi
	((phase_index+=1))
done

run_child "${PYTHON_BIN}" "${MERGE_SCRIPT}" "${TIER}" "${phase_reports[@]}" || {
	merge_status=$?
	echo "ERROR: failed to merge ODH phase reports" >&2
	[[ "${status}" != 0 ]] || status="${merge_status}"
}
if [[ -f "${merged_report}" ]]; then
	if command -v xsltproc >/dev/null 2>&1; then
		xsltproc --stringparam title "e2e-odh-${TIER}" "${ROOT}/scripts/junit-to-html.xsl" "${merged_report}" > "${merged_report%.xml}.html" || echo "WARNING: failed to render HTML report" >&2
	else
		echo "WARNING: xsltproc not found; HTML report unavailable" >&2
	fi
fi
exit "${status}"
