#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Shared local and image entrypoint for ODH tier phases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export OPENSHELL_BIN="${OPENSHELL_BIN:-${ROOT}/target/debug/openshell}"

# Retry transient discovery failures at most three times, with 1s/2s backoff.
# Keep stderr separate so warnings cannot become part of the projected CSV data.
e2e_discovery_oc() {
	if ! command -v oc >/dev/null 2>&1; then
		echo "ERROR: oc is required for e2e image discovery" >&2
		return 1
	fi
	local error_file output error rc attempt=1 delay=1 transient
	error_file="$(mktemp)" || return 1
	while :; do
		if output="$(oc "$@" --request-timeout=30s 2>"${error_file}")"; then
			cat "${error_file}" >&2
			rm -f "${error_file}"
			printf '%s' "${output}"
			return 0
		else
			rc=$?
		fi
		error="$(cat "${error_file}")"
		transient=0
		case "${error}" in
			*Forbidden*|*Unauthorized*) ;;
			*Timeout*|*timeout*|*timed\ out*|*TooManyRequests*|*Too\ Many\ Requests*|*429*|*InternalError*|*ServiceUnavailable*|*connection\ reset*|*connection\ refused*|*EOF*|*temporarily\ unavailable*) transient=1 ;;
		esac
		if [[ "${transient}" == 0 || "${attempt}" -ge 3 ]]; then
			echo "ERROR: oc $* failed (rc=${rc}): ${error}" >&2
			rm -f "${error_file}"
			return "${rc}"
		fi
		echo ">> Transient oc failure; retrying in ${delay}s (${attempt}/3): ${error}" >&2
		if ! sleep "${delay}"; then
			rm -f "${error_file}"
			return 1
		fi
		attempt=$((attempt + 1))
		delay=$((delay * 2))
	done
}

# Resolve unset runtime images from the installed operator CSV. Bash 3.2 is
# supported. Write VARIABLE<TAB>IMAGE lines only after all images validate.
discover_e2e_images() {
	local needed=""
	[[ -n "${GATEWAY_IMAGE:-}" ]]    || needed="${needed} GATEWAY_IMAGE"
	[[ -n "${SANDBOX_IMAGE:-}" ]]    || needed="${needed} SANDBOX_IMAGE"
	[[ -n "${SUPERVISOR_IMAGE:-}" ]] || needed="${needed} SUPERVISOR_IMAGE"

	if [[ -z "${needed}" ]]; then
		echo ">> All runtime images explicitly set; skipping CSV discovery" >&2
		return 0
	fi

	# Check OLM CSV API availability. Distinguish "API absent" from "oc failed".
	local api_output
	api_output="$(e2e_discovery_oc api-resources --api-group=operators.coreos.com -o name)" || return 1
	if ! echo "${api_output}" | grep -qx 'clusterserviceversions.operators.coreos.com'; then
		echo ">> OLM CSV API absent; using explicit images and existing defaults" >&2
		return 0
	fi

	# List CSVs: namespace|name|phase|copiedFrom|reason
	local csv_table csv_ns csv_name csv_phase csv_copied csv_reason product
	csv_table="$(e2e_discovery_oc get clusterserviceversions.operators.coreos.com \
		--all-namespaces \
		-o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.phase}{"|"}{.metadata.labels.olm\.copiedFrom}{"|"}{.status.reason}{"\n"}{end}')" || return 1

	local candidate_count=0 any_match=0 selected=""
	while IFS='|' read -r csv_ns csv_name csv_phase csv_copied csv_reason; do
		[[ -n "${csv_name}" ]] || continue
		# Skip OLM copies.
		[[ -z "${csv_copied}" ]] || continue
		[[ "${csv_reason}" != "Copied" ]] || continue
		# Match known operator prefixes.
		case "${csv_name}" in
			rhods-operator.*)          product="RHOAI" ;;
			opendatahub-operator.*)    product="ODH" ;;
			*) continue ;;
		esac
		any_match=1
		# Only accept Succeeded CSVs.
		if [[ "${csv_phase}" == "Succeeded" ]]; then
			candidate_count=$((candidate_count + 1))
			selected="${product}|${csv_ns}|${csv_name}"
		fi
	done <<< "${csv_table}"

	if [[ "${candidate_count}" -eq 0 ]]; then
		if [[ "${any_match}" -eq 1 ]]; then
			echo "ERROR: expected one Succeeded RHOAI/ODH operator CSV, found 0. Set GATEWAY_IMAGE, SANDBOX_IMAGE, and SUPERVISOR_IMAGE to bypass discovery" >&2
			return 1
		fi
		echo ">> No RHOAI or ODH operator CSV installed; using explicit images and existing defaults" >&2
		return 0
	fi

	if [[ "${candidate_count}" -ne 1 ]]; then
		echo "ERROR: expected one Succeeded RHOAI/ODH operator CSV, found ${candidate_count}. Set GATEWAY_IMAGE, SANDBOX_IMAGE, and SUPERVISOR_IMAGE to bypass discovery" >&2
		return 1
	fi

	product="${selected%%|*}"
	local rest="${selected#*|}"
	csv_ns="${rest%%|*}"
	csv_name="${rest#*|}"
	local source="${csv_ns}/${csv_name}"
	echo ">> Detected ${product} operator CSV ${source}" >&2

	# Registry allowlist per product.
	local allowed_prefix
	case "${product}" in
		RHOAI) allowed_prefix="registry.redhat.io/rhoai/" ;;
		ODH)   allowed_prefix="quay.io/opendatahub/" ;;
	esac

	# Fetch env vars and relatedImages in one request, so they describe the same
	# CSV revision. Tag each row with its source to preserve env precedence.
	local image_data
	image_data="$(e2e_discovery_oc get clusterserviceversions.operators.coreos.com "${csv_name}" \
		-n "${csv_ns}" \
		-o jsonpath='{range .spec.install.spec.deployments[*].spec.template.spec.containers[*].env[*]}{"env|"}{.name}{"|"}{.value}{"\n"}{end}{range .spec.relatedImages[*]}{"related|"}{.name}{"|"}{.image}{"\n"}{end}')" || return 1

	local image_var csv_env_name related_name image source_kind wanted_name
	local row_kind row_name row_value resolved=""
	for image_var in ${needed}; do
		case "${image_var}" in
			GATEWAY_IMAGE) related_name="odh_openshell_gateway_image" ;;
			SANDBOX_IMAGE) related_name="odh_openshell_sandbox_image" ;;
			SUPERVISOR_IMAGE) related_name="odh_openshell_supervisor_image" ;;
		esac
		csv_env_name="RELATED_IMAGE_ODH_OPENSHELL_${image_var}"
		image=""
		for source_kind in env related; do
			if [[ "${source_kind}" == env ]]; then
				wanted_name="${csv_env_name}"
			else
				wanted_name="${related_name}"
			fi
			while IFS='|' read -r row_kind row_name row_value; do
				[[ "${row_kind}" == "${source_kind}" && "${row_name}" == "${wanted_name}" && -n "${row_value}" ]] || continue
				if [[ -n "${image}" && "${image}" != "${row_value}" ]]; then
					echo "ERROR: CSV ${source} has conflicting ${csv_env_name}; set ${image_var} explicitly" >&2
					return 1
				fi
				image="${row_value}"
			done <<< "${image_data}"
			[[ -z "${image}" ]] || break
		done

		if [[ -z "${image}" ]]; then
			echo "ERROR: CSV ${source} has missing ${csv_env_name}; set ${image_var} explicitly" >&2
			return 1
		fi
		# Strict reference validation: lowercase alphanumeric, dots, hyphens,
		# underscores, slashes, followed by @sha256:<64 hex>. Rejects
		# commas, equals, whitespace, and uppercase — preventing Helm
		# --set-string injection.
		if [[ ! "${image}" =~ ^[a-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]]; then
			echo "ERROR: CSV ${source} ${csv_env_name} is not a valid sha256-pinned reference; set ${image_var} explicitly" >&2
			return 1
		fi

		# Registry allowlist: fail closed if the image is not from the
		# expected registry for this product.
		if [[ "${image}" != "${allowed_prefix}"* ]]; then
			echo "ERROR: CSV ${source} ${csv_env_name} does not start with ${allowed_prefix}; set ${image_var} explicitly" >&2
			return 1
		fi

		resolved="${resolved}${image_var}"$'\t'"${image}"$'\n'
	done
	printf '%s' "${resolved}"
}

PLAN_RESOLVER="${ROOT}/e2e/rust/tests/odh/tier_plan.py"
TIERS_FILE="${ROOT}/e2e/rust/tests/odh/tiers.toml"
DEPLOY_SCRIPT="${OPENSHELL_E2E_DEPLOY_SCRIPT:-${SCRIPT_DIR}/openshell-deploy-from-quay.sh}"
TEST_SCRIPT="${OPENSHELL_E2E_PHASE_RUNNER:-${ROOT}/e2e/rust/tests/odh/run-odh-test-tier.sh}"
MERGE_SCRIPT="${OPENSHELL_E2E_REPORT_MERGER:-${SCRIPT_DIR}/merge-e2e-odh-reports.py}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TIER="${1:-}"
if [[ -z "${TIER}" || $# -ne 1 ]]; then
	echo "Usage: $0 <smoke|tier1|tier2|tier3|odh|full>" >&2
	exit 2
fi

plan_json="$("${PYTHON_BIN}" "${PLAN_RESOLVER}" "${TIER}" "${TIERS_FILE}")"
phase_lines="$(printf '%s' "${plan_json}" | "${PYTHON_BIN}" -c 'import json,sys; print(chr(10).join(p["name"]+"|"+p["mode"] for p in json.load(sys.stdin)["phases"]))')"
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

	# Resolve once so every phase uses the same operator release. Explicit
	# per-image overrides take precedence; stdout contains data, never shell code.
	discovered_images="$(discover_e2e_images)" || {
		echo "ERROR: e2e image discovery failed" >&2
		exit 1
	}
	while IFS=$'\t' read -r image_var image_ref; do
		[[ -n "${image_var}" ]] || continue
		case "${image_var}" in
			GATEWAY_IMAGE|SANDBOX_IMAGE|SUPERVISOR_IMAGE)
				export "${image_var}=${image_ref}"
				echo ">> Discovered ${image_var}=${image_ref}"
				;;
			*) echo "ERROR: unexpected discovered image variable: ${image_var}" >&2; exit 1 ;;
		esac
	done <<< "${discovered_images}"
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
merged_report="${results_dir}/e2e-odh-${TIER}-xunit.xml"
html_report="${results_dir}/e2e-odh-${TIER}.html"
rm -f "${merged_report}" "${html_report}"

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
stop_child() {
	local signal="$1" code="$2"
	trap '' INT TERM
	if [[ -n "${child_pid}" ]]; then
		kill -"${signal}" "${child_pid}" 2>/dev/null || true
		wait "${child_pid}" || true
		child_pid=""
	fi
	exit "${code}"
}
run_child() {
	local result=0
	"$@" &
	child_pid=$!
	wait "${child_pid}" || result=$?
	child_pid=""
	return "${result}"
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
			run_child "${TEST_SCRIPT}" "${TIER}" "${phase}" "${phase_report}" || phase_test_status=$?
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
		xsltproc --stringparam title "e2e-odh-${TIER}" "${ROOT}/scripts/junit-to-html.xsl" "${merged_report}" > "${html_report}" || echo "WARNING: failed to render HTML report" >&2
	else
		echo "WARNING: xsltproc not found; HTML report unavailable" >&2
	fi
fi
exit "${status}"
