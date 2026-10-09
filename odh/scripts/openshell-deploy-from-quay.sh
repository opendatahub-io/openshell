#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy OpenShell to the currently logged-in OpenShift cluster using images
# pushed to Quay, or remove a deployment created by this script.
#
# Usage:
#   ./openshell-deploy-from-quay.sh [deploy] [--yes] [--replace-existing] [--mode shared|managed]
#   ./openshell-deploy-from-quay.sh teardown [--yes]
#
# The e2e image entrypoint can run `deploy --yes`, run the tests, then call
# `teardown --yes` from an exit trap. A noninteractive deployment refuses to
# replace an existing namespace unless --replace-existing is also supplied.
#
# Prerequisites:
#   - oc logged in to the target OpenShift cluster with cluster-admin access
#   - helm and openshell installed
#   - Images already pushed to
#     quay.io/opendatahub/odh-openshell-{gateway,supervisor,sandbox}:<tag>
#
# Env overrides:
#   IMAGE_TAG        image tag to deploy (required without Git branch metadata)
#   QUAY_NAMESPACE   quay.io namespace (default: opendatahub)
#   GATEWAY_IMAGE    gateway image reference (bare repository uses IMAGE_TAG)
#   GATEWAY_IMAGE_DIGEST optional gateway digest override
#   SUPERVISOR_IMAGE supervisor image reference (bare repository uses IMAGE_TAG)
#   SANDBOX_IMAGE    sandbox image reference (bare repository uses IMAGE_TAG)
#   NAMESPACE        target k8s namespace (default: openshell)
#   RELEASE          Helm release name (default: openshell)
#   ROUTE_HOST       gateway Route hostname (default: openshell.<apps domain>)
#   GATEWAY_NAME     local CLI gateway name (default: openshift)
#   OPENSHELL_E2E_RUN_ID  run-scoped suffix used by the shared test entrypoint

set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: openshell-deploy-from-quay.sh [deploy|teardown] [--yes] [--replace-existing] [--keep-local-gateway]

  deploy             Deploy OpenShell (default). Prompts before changing the cluster.
  teardown           Remove the Helm release, namespace, and local gateway.
  --yes              Skip the confirmation prompt for automation.
  --replace-existing Permit --yes to replace an existing namespace during deploy.
  --keep-local-gateway Preserve local CLI registration during teardown.
  --mode NAME         Gateway profile declared in tiers.toml (deploy only).
USAGE
}

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

ACTION=deploy
ASSUME_YES=0
REPLACE_EXISTING=0
KEEP_LOCAL_GATEWAY=0
MODE=shared

if [[ "${1:-}" == deploy || "${1:-}" == teardown ]]; then
	ACTION="$1"
	shift
fi

while (( $# > 0 )); do
	case "$1" in
		--yes) ASSUME_YES=1 ;;
		--replace-existing) REPLACE_EXISTING=1 ;;
		--keep-local-gateway) KEEP_LOCAL_GATEWAY=1 ;;
		--mode) shift; [[ $# -gt 0 ]] || fail "--mode requires a value"; MODE="$1" ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; fail "unknown argument: $1" ;;
	esac
	shift
done

if [[ "${ACTION}" == teardown && "${REPLACE_EXISTING}" == 1 ]]; then
	fail "--replace-existing only applies to deploy"
fi
if [[ "${ACTION}" != teardown && "${KEEP_LOCAL_GATEWAY}" == 1 ]]; then
	fail "--keep-local-gateway only applies to teardown"
fi

confirm_action() {
	local response
	if [[ "${ASSUME_YES}" == 1 ]]; then
		return 0
	fi
	read -r -p "$1 [y/N] " response
	[[ "${response}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/e2e/support/gateway-common.sh"
CHART="${REPO_ROOT}/deploy/helm/openshell"
PLAN_RESOLVER="${REPO_ROOT}/e2e/rust/tests/odh/tier_plan.py"
TIERS_FILE="${REPO_ROOT}/e2e/rust/tests/odh/tiers.toml"
PYTHON_BIN="${PYTHON_BIN:-python3}"
OPEN_SHELL="${OPENSHELL_BIN:-openshell}"

QUAY_NAMESPACE="${QUAY_NAMESPACE:-opendatahub}"
NAMESPACE="${NAMESPACE:-openshell}"
RELEASE="${RELEASE:-openshell}"
GATEWAY_NAME="${GATEWAY_NAME:-openshift}"
XDG_CONFIG_DIR="${XDG_CONFIG_HOME-${HOME}/.config}"
MTLS_DIR="${XDG_CONFIG_DIR:+${XDG_CONFIG_DIR}/}openshell/gateways/${GATEWAY_NAME}/mtls"
QNS="quay.io/${QUAY_NAMESPACE}"
DEPLOY_LABEL="openshell.nvidia.com/deployed-by"
DEPLOY_LABEL_VALUE="odh-e2e"
if [[ "${RELEASE}" == *openshell* ]]; then
	HELM_FULLNAME="${RELEASE:0:63}"
else
	HELM_FULLNAME="${RELEASE}-openshell"
	HELM_FULLNAME="${HELM_FULLNAME:0:63}"
fi
HELM_FULLNAME="${HELM_FULLNAME%-}"

for tool in oc helm "${OPEN_SHELL}" "${PYTHON_BIN}"; do
	command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required"
done
if [[ "${ACTION}" == deploy ]]; then
	command -v base64 >/dev/null 2>&1 || fail "base64 is required"
	command -v curl >/dev/null 2>&1 || fail "curl is required"
	[[ -d "${CHART}" ]] || fail "Helm chart not found at ${CHART}"
	mode_json="$("${PYTHON_BIN}" "${PLAN_RESOLVER}" --mode "${MODE}" "${TIERS_FILE}")"
fi

echo ">> Verifying oc session"
oc whoami >/dev/null

if [[ "${ACTION}" == deploy ]]; then
	if ! oc api-resources --api-group=route.openshift.io 2>/dev/null | grep -q routes; then
		fail "route.openshift.io not found; this does not look like an OpenShift cluster"
	fi
fi

if [[ "${ACTION}" == teardown ]]; then
	teardown_status=0
	namespace_resource="$(oc get namespace "${NAMESPACE}" --ignore-not-found -o name)"
	if [[ -n "${namespace_resource}" ]]; then
		owner="$(oc get namespace "${NAMESPACE}" \
			-o go-template='{{index .metadata.labels "openshell.nvidia.com/deployed-by"}}')"
		if [[ "${owner}" != "${DEPLOY_LABEL_VALUE}" ]]; then
			fail "namespace ${NAMESPACE} was not created by this script; refusing to delete it"
		fi
		confirm_action "Remove OpenShell release '${RELEASE}' and namespace '${NAMESPACE}'?"
		echo ">> Uninstalling Helm release '${RELEASE}'"
		helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait 2>/dev/null || true
		echo ">> Deleting namespace '${NAMESPACE}'"
		oc delete namespace "${NAMESPACE}" --wait || teardown_status=$?
	else
		if [[ "${KEEP_LOCAL_GATEWAY}" != 1 ]]; then
			confirm_action "Remove local gateway '${GATEWAY_NAME}'?"
		fi
		echo ">> Namespace '${NAMESPACE}' is already absent"
	fi
	if [[ "${KEEP_LOCAL_GATEWAY}" != 1 ]]; then
		echo ">> Removing local gateway '${GATEWAY_NAME}'"
		"${OPEN_SHELL}" gateway remove "${GATEWAY_NAME}" 2>/dev/null || true
	fi
	if [[ -n "${OPENSHELL_E2E_DEPLOY_STATE_DIR:-}" ]] &&
		[[ -f "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/mtls-created" ]]; then
		rm -f -- "${MTLS_DIR}/ca.crt" "${MTLS_DIR}/tls.crt" "${MTLS_DIR}/tls.key"
		rmdir -- "${MTLS_DIR}" 2>/dev/null || true
		if [[ -f "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/gateway-dir-created" ]]; then
			rmdir -- "${MTLS_DIR%/mtls}" 2>/dev/null || true
		fi
	fi
	if [[ "${teardown_status}" != 0 ]]; then
		fail "namespace ${NAMESPACE} could not be removed"
	fi
	echo ">> Teardown complete"
	exit 0
fi

if [[ -z "${IMAGE_TAG:-}" ]]; then
	if ! branch="$(git -C "${REPO_ROOT}" symbolic-ref --quiet --short HEAD)"; then
		fail "IMAGE_TAG is required when the source tree has no Git branch metadata"
	fi
	IMAGE_TAG="${branch//\//-}"
	IMAGE_TAG="${IMAGE_TAG//[^a-zA-Z0-9._-]/}"
	IMAGE_TAG="${IMAGE_TAG:0:128}"
fi

GATEWAY_IMAGE="${GATEWAY_IMAGE:-${QNS}/odh-openshell-gateway}"
SUPERVISOR_IMAGE="${SUPERVISOR_IMAGE:-${QNS}/odh-openshell-supervisor}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-${QNS}/odh-openshell-sandbox}"
GATEWAY_IMAGE_REF="$(e2e_resolve_image_reference "${GATEWAY_IMAGE}" "${IMAGE_TAG}")"
SUPERVISOR_IMAGE_REF="$(e2e_resolve_image_reference "${SUPERVISOR_IMAGE}" "${IMAGE_TAG}")"
SANDBOX_IMAGE_REF="$(e2e_resolve_image_reference "${SANDBOX_IMAGE}" "${IMAGE_TAG}")"
if [[ -n "${GATEWAY_IMAGE_DIGEST:-}" ]]; then
	[[ "${GATEWAY_IMAGE_DIGEST}" == sha256:* ]] || fail "GATEWAY_IMAGE_DIGEST must start with sha256:"
	GATEWAY_IMAGE_REF="$(e2e_image_reference_repository "${GATEWAY_IMAGE_REF}")@${GATEWAY_IMAGE_DIGEST}"
fi
for image_ref in "${GATEWAY_IMAGE_REF}" "${SUPERVISOR_IMAGE_REF}" "${SANDBOX_IMAGE_REF}"; do
	[[ -n "$(e2e_image_reference_registry "${image_ref}")" ]] ||
		fail "image reference must include a registry: ${image_ref}"
done

if [[ -z "${ROUTE_HOST:-}" ]]; then
	APPS="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
	if [[ -n "${OPENSHELL_E2E_RUN_ID:-}" ]]; then
		ROUTE_HOST="openshell-${OPENSHELL_E2E_RUN_ID}.${APPS}"
	else
		ROUTE_HOST="openshell.${APPS}"
	fi
fi

echo
echo "====================================================="
echo "  Deploy OpenShell on OpenShift using custom images"
echo "====================================================="
echo "  Cluster:      $(oc whoami --show-server)"
echo "  User:         $(oc whoami)"
echo "  Namespace:    ${NAMESPACE}"
echo "  Helm release: ${RELEASE}"
echo "  Gateway name: ${GATEWAY_NAME}"
echo "  Route host:   ${ROUTE_HOST}"
echo "  Images:"
echo "    - ${GATEWAY_IMAGE_REF}"
echo "    - ${SUPERVISOR_IMAGE_REF}"
echo "    - ${SANDBOX_IMAGE_REF}"
echo "  Actions:"
echo "    1. Replace namespace '${NAMESPACE}' if it exists"
echo "    2. Create namespace"
echo "    3. Deploy Helm release '${RELEASE}' and wait for the gateway"
echo "    4. Register local gateway '${GATEWAY_NAME}'"
echo "====================================================="
echo

namespace_resource="$(oc get namespace "${NAMESPACE}" --ignore-not-found -o name)"
if [[ -n "${namespace_resource}" ]]; then
	owner="$(oc get namespace "${NAMESPACE}" \
		-o go-template='{{index .metadata.labels "openshell.nvidia.com/deployed-by"}}')"
	[[ "${owner}" == "${DEPLOY_LABEL_VALUE}" ]] ||
		fail "namespace ${NAMESPACE} was not created by this script; refusing to replace it"
fi
if [[ -n "${namespace_resource}" ]] &&
	[[ "${ASSUME_YES}" == 1 && "${REPLACE_EXISTING}" != 1 ]]; then
	fail "namespace ${NAMESPACE} already exists; pass --replace-existing to replace it noninteractively"
fi

confirm_action "Proceed with deploy?"

if [[ -n "${namespace_resource}" ]]; then
	echo ">> Uninstalling Helm release '${RELEASE}' (if present)"
	helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait 2>/dev/null || true
	echo ">> Deleting namespace '${NAMESPACE}'"
	oc delete namespace "${NAMESPACE}" --wait
fi

echo ">> Removing local gateway '${GATEWAY_NAME}' (if present)"
"${OPEN_SHELL}" gateway remove "${GATEWAY_NAME}" 2>/dev/null || true

echo ">> Creating namespace '${NAMESPACE}'"
# Apply the ownership label in the create request, so a failed label update
# cannot leave behind a namespace that teardown refuses to remove.
if [[ -n "${OPENSHELL_E2E_DEPLOY_STATE_DIR:-}" ]]; then
	: > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/namespace"
fi
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml |
	oc label --local -f - "${DEPLOY_LABEL}=${DEPLOY_LABEL_VALUE}" -o yaml |
	oc create -f -

if [[ "${MODE}" == managed ]]; then
	echo ">> Creating managed-workspace image-pull Secret"
	oc -n "${NAMESPACE}" create secret docker-registry e2e-regcred \
		--docker-server=registry.example.test \
		--docker-username=e2e-user \
		--docker-password=e2e-password
	oc -n "${NAMESPACE}" label secret e2e-regcred \
		openshell.ai/sandbox-attachable=true
fi

echo ">> Deploying OpenShell via Helm"
helm_value_args=()
helm_value_args+=(--values "${REPO_ROOT}/deploy/helm/openshell/ci/values-openshift-scc.yaml")
helm_value_args+=(--values "${REPO_ROOT}/deploy/helm/openshell/ci/values-openshift-e2e.yaml")
helm_value_args+=(--values "${REPO_ROOT}/odh/values-openshift-e2e.yaml")
overlay_lines="$(printf '%s' "${mode_json}" | "${PYTHON_BIN}" -c 'import json,sys; print(chr(10).join(json.load(sys.stdin)["helm_values"]))')"
if [[ -n "${overlay_lines}" ]]; then
	while IFS= read -r value_file; do
		helm_value_args+=(--values "${REPO_ROOT}/${value_file}")
	done <<< "${overlay_lines}"
fi
image_helm_args=()
append_image_helm_args() {
	local component="$1" image_ref="$2" value
	for value in \
		"registry=$(e2e_image_reference_registry "${image_ref}")" \
		"repository=$(e2e_image_reference_repository_path "${image_ref}")" \
		"tag=$(e2e_image_reference_tag "${image_ref}")" \
		"digest=$(e2e_image_reference_digest "${image_ref}")"; do
		image_helm_args+=(--set-string "${component}.image.${value}")
	done
}
append_image_helm_args gateway "${GATEWAY_IMAGE_REF}"
append_image_helm_args supervisor "${SUPERVISOR_IMAGE_REF}"
append_image_helm_args sandboxRuntime "${SANDBOX_IMAGE_REF}"
helm upgrade --install "${RELEASE}" "${CHART}" \
	--namespace "${NAMESPACE}" --create-namespace \
	"${helm_value_args[@]}" \
	"${image_helm_args[@]}" \
	--set "openshiftRoute.host=${ROUTE_HOST}" \
	--set "pkiInitJob.serverDnsNames[0]=${ROUTE_HOST}"

echo ">> Waiting for gateway rollout"
if ! oc -n "${NAMESPACE}" rollout status "statefulset/${HELM_FULLNAME}" --timeout=300s; then
	oc -n "${NAMESPACE}" get pods
	fail "gateway did not become ready"
fi
oc -n "${NAMESPACE}" wait "route/${HELM_FULLNAME}" \
	--for='jsonpath={.status.ingress[0].conditions[?(@.type=="Admitted")].status}=True' \
	--timeout=120s

# Extract client mTLS materials so the CLI can reach the mandatory-mTLS gateway.
echo ">> Writing client mTLS materials to ${MTLS_DIR}"
if [[ -n "${OPENSHELL_E2E_DEPLOY_STATE_DIR:-}" ]] &&
	[[ ! -e "${MTLS_DIR%/mtls}" && ! -L "${MTLS_DIR%/mtls}" ]]; then
	: > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/gateway-dir-created"
fi
if [[ -n "${OPENSHELL_E2E_DEPLOY_STATE_DIR:-}" ]] &&
	[[ ! -e "${MTLS_DIR}" && ! -L "${MTLS_DIR}" ]]; then
	: > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/mtls-created"
fi
umask 077
mkdir -p "${MTLS_DIR}"
chmod 0700 "${MTLS_DIR}"
for mtls_file in ca.crt tls.crt tls.key; do
	: > "${MTLS_DIR}/${mtls_file}"
	chmod 0600 "${MTLS_DIR}/${mtls_file}"
done
oc -n "${NAMESPACE}" get secret openshell-client-tls \
	-o jsonpath='{.data.ca\.crt}' | base64 -d > "${MTLS_DIR}/ca.crt"
oc -n "${NAMESPACE}" get secret openshell-client-tls \
	-o jsonpath='{.data.tls\.crt}' | base64 -d > "${MTLS_DIR}/tls.crt"
oc -n "${NAMESPACE}" get secret openshell-client-tls \
	-o jsonpath='{.data.tls\.key}' | base64 -d > "${MTLS_DIR}/tls.key"

auth_check_dir=""
cleanup_auth_check() {
	if [[ -n "${auth_check_dir}" ]]; then
		rm -rf "${auth_check_dir}"
	fi
}
trap cleanup_auth_check EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

auth_check_dir="$(mktemp -d)"
auth_check_request="${auth_check_dir}/request"
auth_check_headers="${auth_check_dir}/headers"
auth_check_status="${auth_check_dir}/status"
auth_check_error="${auth_check_dir}/error"
printf '\000\000\000\000\000' > "${auth_check_request}"

probe_list_sandboxes() {
	local curl_timeout="$1"
	curl --disable --silent --show-error --noproxy '*' --http2 \
		--cacert "${MTLS_DIR}/ca.crt" \
		--output /dev/null --dump-header "${auth_check_headers}" \
		--write-out '%{http_code}' --connect-timeout 10 --max-time "${curl_timeout}" \
		--header 'content-type: application/grpc' --header 'te: trailers' \
		--data-binary "@${auth_check_request}" \
		"https://${ROUTE_HOST}/openshell.v1.OpenShell/ListSandboxes" \
		> "${auth_check_status}" 2> "${auth_check_error}"
}

	echo ">> Waiting for OpenShift Route to reject unauthenticated ListSandboxes RPCs"
route_deadline=$((SECONDS + 180))
route_ready=0
route_probe_error=""
while (( SECONDS < route_deadline )); do
	remaining=$((route_deadline - SECONDS))
	(( remaining > 0 )) || break
	curl_timeout=10
	if (( remaining < curl_timeout )); then curl_timeout="${remaining}"; fi
	if probe_list_sandboxes "${curl_timeout}"; then
		auth_check_http_status="$(cat "${auth_check_status}")"
		route_grpc_status=""
		if [[ -f "${auth_check_headers}" ]]; then
			route_grpc_status="$(awk 'tolower($1) == "grpc-status:" { gsub("\\r", "", $2); status = $2 } END { print status }' "${auth_check_headers}")"
		fi
		if [[ "${auth_check_http_status}" == 200 ]] &&
			[[ "${route_grpc_status}" == 16 ]]; then
			route_ready=1
			break
		fi
		if [[ "${auth_check_http_status}" == 503 || "${route_grpc_status}" == 14 ]]; then
			route_probe_error="HTTP ${auth_check_http_status:-unknown}"
			if [[ "${route_grpc_status}" == 14 ]]; then
				route_probe_error+=", grpc-status 14"
			fi
		else
			rm -rf "${auth_check_dir}"
			fail "unauthenticated ListSandboxes RPC was not rejected (HTTP ${auth_check_http_status:-unknown}, grpc-status ${route_grpc_status:-missing})"
		fi
	else
		curl_status=$?
		route_probe_error="$(cat "${auth_check_error}")"
		case "${curl_status}" in
			5|6|7|16|18|28|35|52|55|56|92)
				route_probe_error="curl exit ${curl_status}: ${route_probe_error}"
				;;
			*)
				rm -rf "${auth_check_dir}"
				fail "client-certificate route probe failed with curl exit ${curl_status}: ${route_probe_error}"
				;;
		esac
	fi
	remaining=$((route_deadline - SECONDS))
	(( remaining > 0 )) || break
	sleep_seconds=3
	if (( remaining < sleep_seconds )); then sleep_seconds="${remaining}"; fi
	sleep "${sleep_seconds}"
done
if [[ "${route_ready}" != 1 ]]; then
	rm -rf "${auth_check_dir}"
	fail "OpenShift Route did not reject unauthenticated ListSandboxes RPCs within 180s: ${route_probe_error}"
fi

rm -rf "${auth_check_dir}"

echo ">> Registering gateway '${GATEWAY_NAME}' in the local CLI"
if [[ -n "${OPENSHELL_E2E_DEPLOY_STATE_DIR:-}" ]]; then
	: > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/gateway"
fi
"${OPEN_SHELL}" gateway add "https://${ROUTE_HOST}" --local --name "${GATEWAY_NAME}"

echo ">> Checking deployed gateway mode '${MODE}'"
expected_values="$(printf '%s' "${mode_json}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["expected_helm_values"]))')"
helm get values "${RELEASE}" --namespace "${NAMESPACE}" --all -o json |
	"${PYTHON_BIN}" -c '
import json, sys
expected = json.loads(sys.argv[1])
actual = json.load(sys.stdin)
def subset(want, got, path=""):
    for key, value in want.items():
        current = f"{path}.{key}" if path else key
        if key not in got:
            raise SystemExit(f"mode preflight missing Helm value {current}")
        if isinstance(value, dict):
            if not isinstance(got[key], dict):
                raise SystemExit(f"mode preflight mismatch for {current}")
            subset(value, got[key], current)
        elif got[key] != value:
            raise SystemExit(f"mode preflight mismatch for {current}: expected {value!r}, got {got[key]!r}")
subset(expected, actual)
' "${expected_values}"

echo
echo ">> Done. Verify with:"
echo "     oc -n ${NAMESPACE} get pods,route"
echo "     openshell gateway select ${GATEWAY_NAME}"
echo "     openshell status"
