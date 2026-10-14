#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy OpenShell to the currently logged-in OpenShift cluster using images
# pushed to Quay, or remove a deployment created by this script.
#
# Usage:
#   ./openshell-deploy-from-quay.sh [deploy] [--yes] [--replace-existing]
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
#   GATEWAY_IMAGE    full gateway image repository override
#   GATEWAY_IMAGE_DIGEST optional gateway digest, overriding IMAGE_TAG for Helm
#   SUPERVISOR_IMAGE full supervisor image repository override
#   SUPERVISOR_IMAGE_DIGEST optional supervisor digest, overriding IMAGE_TAG for Helm
#   SANDBOX_IMAGE    full sandbox image repository override
#   SANDBOX_IMAGE_DIGEST optional sandbox runtime digest, overriding IMAGE_TAG for Helm
#   WORKLOAD_IMAGE   optional default sandbox workload image repository override
#   WORKLOAD_IMAGE_TAG optional workload image tag (default: latest)
#   WORKLOAD_IMAGE_DIGEST optional workload image digest, overriding WORKLOAD_IMAGE_TAG
#   NAMESPACE        target k8s namespace (default: openshell)
#   RELEASE          Helm release name (default: openshell)
#   ROUTE_HOST       gateway Route hostname (default: openshell.<apps domain>)
#   GATEWAY_NAME     local CLI gateway name (default: openshift)

set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: openshell-deploy-from-quay.sh [deploy|teardown] [--yes] [--replace-existing] [--keep-local-gateway]

  deploy             Deploy OpenShell (default). Prompts before changing the cluster.
  teardown           Remove the Helm release, namespace, and local gateway.
  --yes              Skip the confirmation prompt for automation.
  --replace-existing Permit --yes to replace an existing namespace during deploy.
  --keep-local-gateway Preserve local CLI registration during teardown.
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

if [[ "${1:-}" == deploy || "${1:-}" == teardown ]]; then
	ACTION="$1"
	shift
fi

while (( $# > 0 )); do
	case "$1" in
		--yes) ASSUME_YES=1 ;;
		--replace-existing) REPLACE_EXISTING=1 ;;
		--keep-local-gateway) KEEP_LOCAL_GATEWAY=1 ;;
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
CHART="${REPO_ROOT}/deploy/helm/openshell"

QUAY_NAMESPACE="${QUAY_NAMESPACE:-opendatahub}"
NAMESPACE="${NAMESPACE:-openshell}"
RELEASE="${RELEASE:-openshell}"
GATEWAY_NAME="${GATEWAY_NAME:-openshift}"
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

for tool in oc helm openshell; do
	command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required"
done
if [[ "${ACTION}" == deploy ]]; then
	command -v base64 >/dev/null 2>&1 || fail "base64 is required"
	[[ -d "${CHART}" ]] || fail "Helm chart not found at ${CHART}"
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
		openshell gateway remove "${GATEWAY_NAME}" 2>/dev/null || true
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

validate_image_digest() {
	local name="$1" digest="$2"
	[[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]] || fail "${name} must be a lowercase sha256 digest"
}

validate_image_repository() {
	local name="$1" repository="$2"
	[[ "${repository}" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?(/[a-z0-9][a-z0-9._-]*)+$ ]] \
		|| fail "${name} must be a lowercase registry/repository reference without Helm separators"
}

validate_image_tag() {
	local name="$1" tag="$2"
	[[ "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
		|| fail "${name} must be a valid image tag without Helm separators"
}

validate_image_tag IMAGE_TAG "${IMAGE_TAG}"

# An image override may include its immutable digest directly
# (registry/repository@sha256:...). Helm requires the repository and digest
# as separate values, so split it before constructing the chart arguments.
# An explicit *_IMAGE_DIGEST takes precedence only when it agrees with the
# inline digest; silently choosing one could deploy a different image than the
# caller intended.
normalize_image_override() {
	local image_var="$1" digest_var="$2"
	local image="${!image_var}" digest repository explicit_digest
	if [[ "${image}" != *@* ]]; then
		return
	fi
	repository="${image%@*}"
	digest="${image##*@}"
	[[ -n "${repository}" && "${repository}" != *"@"* ]] \
		|| fail "${image_var} must contain one repository and digest"
	validate_image_digest "${image_var} digest" "${digest}"
	explicit_digest="${!digest_var:-}"
	if [[ -n "${explicit_digest}" && "${explicit_digest}" != "${digest}" ]]; then
		fail "${image_var} digest conflicts with ${digest_var}"
	fi
	printf -v "${image_var}" '%s' "${repository}"
	printf -v "${digest_var}" '%s' "${digest}"
}

GATEWAY_IMAGE="${GATEWAY_IMAGE:-${QNS}/odh-openshell-gateway}"
SUPERVISOR_IMAGE="${SUPERVISOR_IMAGE:-${QNS}/odh-openshell-supervisor}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-${QNS}/odh-openshell-sandbox}"
normalize_image_override GATEWAY_IMAGE GATEWAY_IMAGE_DIGEST
normalize_image_override SUPERVISOR_IMAGE SUPERVISOR_IMAGE_DIGEST
normalize_image_override SANDBOX_IMAGE SANDBOX_IMAGE_DIGEST
validate_image_repository GATEWAY_IMAGE "${GATEWAY_IMAGE}"
validate_image_repository SUPERVISOR_IMAGE "${SUPERVISOR_IMAGE}"
validate_image_repository SANDBOX_IMAGE "${SANDBOX_IMAGE}"
GATEWAY_REGISTRY="${GATEWAY_IMAGE%%/*}"
GATEWAY_REPOSITORY="${GATEWAY_IMAGE#*/}"
SUPERVISOR_REGISTRY="${SUPERVISOR_IMAGE%%/*}"
SUPERVISOR_REPOSITORY="${SUPERVISOR_IMAGE#*/}"
SANDBOX_REGISTRY="${SANDBOX_IMAGE%%/*}"
SANDBOX_REPOSITORY="${SANDBOX_IMAGE#*/}"
GATEWAY_IMAGE_REF="${GATEWAY_IMAGE}:${IMAGE_TAG}"
SUPERVISOR_IMAGE_REF="${SUPERVISOR_IMAGE}:${IMAGE_TAG}"
SANDBOX_IMAGE_REF="${SANDBOX_IMAGE}:${IMAGE_TAG}"
WORKLOAD_IMAGE_REF=""
if [[ -n "${WORKLOAD_IMAGE:-}" ]]; then
	normalize_image_override WORKLOAD_IMAGE WORKLOAD_IMAGE_DIGEST
	validate_image_repository WORKLOAD_IMAGE "${WORKLOAD_IMAGE}"
	WORKLOAD_IMAGE_TAG="${WORKLOAD_IMAGE_TAG:-latest}"
	validate_image_tag WORKLOAD_IMAGE_TAG "${WORKLOAD_IMAGE_TAG}"
	WORKLOAD_IMAGE_REF="${WORKLOAD_IMAGE}:${WORKLOAD_IMAGE_TAG}"
elif [[ -n "${WORKLOAD_IMAGE_DIGEST:-}" || -n "${WORKLOAD_IMAGE_TAG:-}" ]]; then
	fail "WORKLOAD_IMAGE is required when setting WORKLOAD_IMAGE_TAG or WORKLOAD_IMAGE_DIGEST"
fi
if [[ -z "${ROUTE_HOST:-}" ]]; then
	APPS="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
	ROUTE_HOST="openshell.${APPS}"
fi

HELM_ARGS=(
	upgrade --install "${RELEASE}" "${CHART}"
	--namespace "${NAMESPACE}" --create-namespace
	--set-string "gateway.image.registry=${GATEWAY_REGISTRY}"
	--set-string "gateway.image.repository=${GATEWAY_REPOSITORY}"
	--set-string "gateway.image.tag=${IMAGE_TAG}"
	--set-string "supervisor.image.registry=${SUPERVISOR_REGISTRY}"
	--set-string "supervisor.image.repository=${SUPERVISOR_REPOSITORY}"
	--set-string "supervisor.image.tag=${IMAGE_TAG}"
	--set-string "sandboxRuntime.image.registry=${SANDBOX_REGISTRY}"
	--set-string "sandboxRuntime.image.repository=${SANDBOX_REPOSITORY}"
	--set-string "sandboxRuntime.image.tag=${IMAGE_TAG}"
	--set "sandbox.image.pullPolicy=IfNotPresent"
	--set "podSecurityContext.fsGroup=null"
	--set "securityContext.runAsUser=null"
	--set "openshiftRoute.enabled=true"
	--set "openshiftRoute.host=${ROUTE_HOST}"
	--set "pkiInitJob.serverDnsNames[0]=${ROUTE_HOST}"
	# The Route is passthrough: the gateway, rather than the router, owns TLS
	# and client identity. Keep unauthenticated user promotion disabled so a
	# caller without an mTLS identity cannot access protected user RPCs.
	--set-string "openshiftRoute.annotations.haproxy\\.router\\.openshift\\.io/timeout=300s"
	--set-string "openshiftRoute.annotations.haproxy\\.router\\.openshift\\.io/timeout-tunnel=300s"
)
if [[ -n "${WORKLOAD_IMAGE_REF}" ]]; then
	HELM_ARGS+=(
		--set-string "sandbox.image.repository=${WORKLOAD_IMAGE}"
		--set-string "sandbox.image.tag=${WORKLOAD_IMAGE_TAG}"
	)
fi
if [[ -n "${GATEWAY_IMAGE_DIGEST:-}" ]]; then
	validate_image_digest GATEWAY_IMAGE_DIGEST "${GATEWAY_IMAGE_DIGEST}"
	HELM_ARGS+=(--set-string "gateway.image.digest=${GATEWAY_IMAGE_DIGEST}")
	GATEWAY_IMAGE_REF="${GATEWAY_IMAGE}@${GATEWAY_IMAGE_DIGEST}"
fi
if [[ -n "${SUPERVISOR_IMAGE_DIGEST:-}" ]]; then
	validate_image_digest SUPERVISOR_IMAGE_DIGEST "${SUPERVISOR_IMAGE_DIGEST}"
	HELM_ARGS+=(--set-string "supervisor.image.digest=${SUPERVISOR_IMAGE_DIGEST}")
	SUPERVISOR_IMAGE_REF="${SUPERVISOR_IMAGE}@${SUPERVISOR_IMAGE_DIGEST}"
fi
if [[ -n "${SANDBOX_IMAGE_DIGEST:-}" ]]; then
	validate_image_digest SANDBOX_IMAGE_DIGEST "${SANDBOX_IMAGE_DIGEST}"
	HELM_ARGS+=(--set-string "sandboxRuntime.image.digest=${SANDBOX_IMAGE_DIGEST}")
	SANDBOX_IMAGE_REF="${SANDBOX_IMAGE}@${SANDBOX_IMAGE_DIGEST}"
fi
if [[ -n "${WORKLOAD_IMAGE_DIGEST:-}" ]]; then
	validate_image_digest WORKLOAD_IMAGE_DIGEST "${WORKLOAD_IMAGE_DIGEST}"
	HELM_ARGS+=(--set-string "sandbox.image.digest=${WORKLOAD_IMAGE_DIGEST}")
	WORKLOAD_IMAGE_REF="${WORKLOAD_IMAGE}@${WORKLOAD_IMAGE_DIGEST}"
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
if [[ -n "${WORKLOAD_IMAGE_REF}" ]]; then
	echo "    - ${WORKLOAD_IMAGE_REF} (default sandbox workload)"
fi
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
openshell gateway remove "${GATEWAY_NAME}" 2>/dev/null || true

echo ">> Creating namespace '${NAMESPACE}'"
# Apply the ownership label in the create request, so a failed label update
# cannot leave behind a namespace that teardown refuses to remove.
if [[ -n "${OPENSHELL_E2E_DEPLOY_STATE_DIR:-}" ]]; then
	: > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/namespace"
fi
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml |
	oc label --local -f - "${DEPLOY_LABEL}=${DEPLOY_LABEL_VALUE}" -o yaml |
	oc create -f -

echo ">> Deploying OpenShell via Helm"
helm "${HELM_ARGS[@]}"

echo ">> Waiting for gateway rollout"
if ! oc -n "${NAMESPACE}" rollout status "statefulset/${HELM_FULLNAME}" --timeout=300s; then
	oc -n "${NAMESPACE}" get pods
	fail "gateway did not become ready"
fi

# Extract client mTLS materials so the CLI can reach the mandatory-mTLS gateway.
MTLS_DIR="${HOME}/.config/openshell/gateways/${GATEWAY_NAME}/mtls"
echo ">> Writing client mTLS materials to ${MTLS_DIR}"
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

echo ">> Registering gateway '${GATEWAY_NAME}' in the local CLI"
if [[ -n "${OPENSHELL_E2E_DEPLOY_STATE_DIR:-}" ]]; then
	: > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/gateway"
fi
openshell gateway add "https://${ROUTE_HOST}" --local --name "${GATEWAY_NAME}"

echo
echo ">> Done. Verify with:"
echo "     oc -n ${NAMESPACE} get pods,route"
echo "     openshell gateway select ${GATEWAY_NAME}"
echo "     openshell status"
