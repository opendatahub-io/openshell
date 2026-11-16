#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Shared state and helpers for the OIDC fixture scripts. Sourced by setup.sh,
# cleanup.sh, and diagnostics.sh; never executed directly.
#
# Run state is deliberately split into two files with different contracts:
#
#   <state-dir>/fixture.env  the operational contract: derived issuer,
#                            endpoint, CA material, and Helm values overlay
#                            the ODH entrypoint consumes. It is credential-
#                            free by construction and the only file any
#                            component outside the fixture reads.
#   <state-dir>/state.env    the fixture's private run state: namespaces,
#                            resource names, and the ownership label. Only
#                            the fixture scripts source it.
#
# No credential or private key is ever written to either file: the database
# password is generated in memory and passed to its Secret through a file
# descriptor, and the TLS private keys are removed as soon as the serving
# certificate is stored in the cluster.

FIXTURE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_ROOT="$(cd "${FIXTURE_LIB_DIR}/../.." && pwd)"
# Consumed by the sourced setup.sh and diagnostics.sh subscripts.
# shellcheck disable=SC2034
FIXTURE_SCRIPTS_DIR="${FIXTURE_ROOT}/scripts"

fixture_fail() { echo "ERROR: $*" >&2; exit 1; }

fixture_require_tools() {
	for tool in oc openssl "${PYTHON_BIN:-python3}"; do
		command -v "${tool}" >/dev/null 2>&1 || fixture_fail "${tool} is required"
	done
}

# Derive every run-scoped name from OPENSHELL_E2E_RUN_ID and the caller
# environment. Deterministic, so a setup failure before state.env exists can
# still clean up exactly what was created.
fixture_derive_names() {
	RUN_ID="${OPENSHELL_E2E_RUN_ID:-}"
	[[ -n "${RUN_ID}" ]] || fixture_fail "OPENSHELL_E2E_RUN_ID is required"
	# RHBK derives a Service named "${RESOURCE_PREFIX}-keycloak-discovery".
	# Kubernetes resource names are limited to 63 characters, leaving 29 for
	# the per-run suffix after the fixed prefix and derived suffix.
	[[ "${RUN_ID}" =~ ^[a-z0-9]([a-z0-9-]{0,27}[a-z0-9])?$ ]] \
		|| fixture_fail "OPENSHELL_E2E_RUN_ID must be 1-29 lowercase DNS-safe characters"
	RESOURCE_PREFIX="openshell-oidc-${RUN_ID}"
	LABEL_KEY="openshell.nvidia.com/oidc-run"
	LABEL_VALUE="${RUN_ID}"
	KEYCLOAK_NAME="${RESOURCE_PREFIX}-keycloak"
	POSTGRES_NAME="${RESOURCE_PREFIX}-postgres"
	REALM_IMPORT_NAME="${RESOURCE_PREFIX}-realm"
	TLS_SECRET_NAME="${RESOURCE_PREFIX}-keycloak-tls"
	DB_SECRET_NAME="${RESOURCE_PREFIX}-postgres"
	FIXTURE_CA_CONFIG_MAP_NAME="${RESOURCE_PREFIX}-ca"
	KEYCLOAK_ROUTE_NAME="${RESOURCE_PREFIX}-keycloak"
	FIXTURE_NAMESPACE="${OPENSHELL_E2E_RHBK_NAMESPACE:-${RESOURCE_PREFIX}-rhbk}"
	GATEWAY_NAMESPACE="${NAMESPACE:-openshell}"
	GATEWAY_RELEASE="${RELEASE:-openshell}"
}

fixture_operational_env_path() { printf '%s/fixture.env\n' "$1"; }
fixture_internal_state_path() { printf '%s/state.env\n' "$1"; }

# Record the fixture-private run state as soon as the namespace decision is
# made, so cleanup and diagnostics always describe what setup actually used.
fixture_write_internal_state() {
	local state_dir="$1" created="${2:-0}" namespace_uid="${3:-}" delete_requested="${4:-0}"
	{
		# %q makes state.env safe to source even when a caller-controlled
		# namespace or release contains shell metacharacters.
		printf 'FIXTURE_NAMESPACE=%q\n' "${FIXTURE_NAMESPACE}"
		printf 'GATEWAY_NAMESPACE=%q\n' "${GATEWAY_NAMESPACE}"
		printf 'GATEWAY_RELEASE=%q\n' "${GATEWAY_RELEASE}"
		printf 'LABEL_KEY=%q\n' "${LABEL_KEY}"
		printf 'LABEL_VALUE=%q\n' "${LABEL_VALUE}"
		printf 'KEYCLOAK_NAME=%q\n' "${KEYCLOAK_NAME}"
		printf 'POSTGRES_NAME=%q\n' "${POSTGRES_NAME}"
		printf 'REALM_IMPORT_NAME=%q\n' "${REALM_IMPORT_NAME}"
		printf 'TLS_SECRET_NAME=%q\n' "${TLS_SECRET_NAME}"
		printf 'DB_SECRET_NAME=%q\n' "${DB_SECRET_NAME}"
		printf 'FIXTURE_CA_CONFIG_MAP_NAME=%q\n' "${FIXTURE_CA_CONFIG_MAP_NAME}"
		printf 'KEYCLOAK_ROUTE_NAME=%q\n' "${KEYCLOAK_ROUTE_NAME}"
		printf 'FIXTURE_NAMESPACE_CREATED=%q\n' "${created}"
		printf 'FIXTURE_NAMESPACE_UID=%q\n' "${namespace_uid}"
		printf 'FIXTURE_NAMESPACE_DELETE_REQUESTED=%q\n' "${delete_requested}"
	} > "$(fixture_internal_state_path "${state_dir}")"
	chmod 600 "$(fixture_internal_state_path "${state_dir}")"
}

# Load the private run state; derive it from the environment when setup failed
# before the state file existed (the names are deterministic, so both paths
# describe the same resources).
fixture_load_internal_state() {
	local state_dir="$1"
	if [[ -f "$(fixture_internal_state_path "${state_dir}")" ]]; then
		# shellcheck disable=SC1090
		source "$(fixture_internal_state_path "${state_dir}")"
	else
		fixture_derive_names
		# Setup can fail while writing state.env. Keep cleanup safe under
		# `set -u`; no namespace was recorded as created in that case.
		FIXTURE_NAMESPACE_CREATED=0
	fi
}

# Bounded verification that a requested deletion actually completed:
# --wait=false only proves the delete was accepted, so poll until the
# resource is gone. A timeout fails cleanup loudly instead of letting a
# half-deleted fixture pass as clean.
CLEANUP_VERIFY_ATTEMPTS="${OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_ATTEMPTS:-24}"
CLEANUP_VERIFY_SLEEP="${OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_SLEEP:-5}"

fixture_resource_exists() {
	local kind="$1" name="$2" output
	if ! output="$(oc -n "${FIXTURE_NAMESPACE}" get "${kind}" "${name}" --ignore-not-found -o name 2>/dev/null)"; then
		echo "ERROR: could not verify whether ${kind} ${name} was deleted" >&2
		return 2
	fi
	[[ -n "${output}" ]]
}

fixture_namespace_exists() {
	local output
	if ! output="$(oc get namespace "${FIXTURE_NAMESPACE}" --ignore-not-found -o name 2>/dev/null)"; then
		echo "ERROR: could not verify whether namespace ${FIXTURE_NAMESPACE} was deleted" >&2
		return 2
	fi
	[[ -n "${output}" ]]
}

# Return 0 when the current namespace has the recorded UID, 1 when it is
# already absent, and 2/3 for an API error or a different live object. The
# UID check prevents a retained cleanup state from deleting a replacement
# namespace with the same name.
fixture_namespace_matches_uid() {
	local current_uid
	if ! current_uid="$(oc get namespace "${FIXTURE_NAMESPACE}" --ignore-not-found \
		-o jsonpath='{.metadata.uid}' 2>/dev/null)"; then
		echo "ERROR: could not verify identity of namespace ${FIXTURE_NAMESPACE}" >&2
		return 2
	fi
	if [[ -z "${current_uid}" ]]; then
		return 1
	fi
	if [[ "${current_uid}" != "${FIXTURE_NAMESPACE_UID}" ]]; then
		echo "ERROR: namespace ${FIXTURE_NAMESPACE} UID changed; refusing cleanup" >&2
		return 3
	fi
}

fixture_wait_for_resource_absence() {
	local kind="$1" name="$2" attempt=0 probe_status
	while true; do
		if fixture_resource_exists "${kind}" "${name}"; then
			attempt=$((attempt + 1))
			if (( attempt >= CLEANUP_VERIFY_ATTEMPTS )); then
				echo "ERROR: ${kind} ${name} was still present ${attempt} checks after deletion" >&2
				return 1
			fi
			sleep "${CLEANUP_VERIFY_SLEEP}"
		else
			probe_status=$?
			if (( probe_status == 2 )); then
				return 1
			fi
			return 0
		fi
	done
}

fixture_wait_for_namespace_absence() {
	local attempt=0 probe_status
	while true; do
		if fixture_namespace_exists; then
			attempt=$((attempt + 1))
			if (( attempt >= CLEANUP_VERIFY_ATTEMPTS )); then
				echo "ERROR: namespace ${FIXTURE_NAMESPACE} was still present ${attempt} checks after deletion" >&2
				return 1
			fi
			sleep "${CLEANUP_VERIFY_SLEEP}"
		else
			probe_status=$?
			if (( probe_status == 2 )); then
				return 1
			fi
			return 0
		fi
	done
}

# A deterministic resource name is not proof that this run created the
# object: the fixture may use a caller-owned namespace. Ask the API server to
# apply the ownership selector before deleting anything. An empty successful
# response means the resource is absent or belongs to another run and must be
# left alone; a failed read is a cleanup error, not evidence of absence.
fixture_resource_is_owned() {
	local kind="$1" name="$2" output
	FIXTURE_RESOURCE_OWNED=0
	FIXTURE_RESOURCE_UID=""
	if ! output="$(oc -n "${FIXTURE_NAMESPACE}" get "${kind}" \
		-l "${LABEL_KEY}=${LABEL_VALUE}" \
		--ignore-not-found -o json 2>/dev/null)"; then
		echo "ERROR: could not verify ownership of ${kind} ${name}" >&2
		return 1
	fi
	if ! FIXTURE_RESOURCE_UID="$(printf '%s' "${output}" | "${PYTHON_BIN:-python3}" -c '
import json
import sys

name = sys.argv[1]
document = json.load(sys.stdin)
items = document.get("items", [])
if not items and document.get("metadata", {}).get("name") == name:
    items = [document]
for item in items:
    metadata = item.get("metadata", {})
    if metadata.get("name") == name:
        print(metadata.get("uid", ""))
        break
' "${name}")"; then
		echo "ERROR: could not parse ownership of ${kind} ${name}" >&2
		return 1
	fi
	if [[ -n "${FIXTURE_RESOURCE_UID}" ]]; then
		FIXTURE_RESOURCE_OWNED=1
	fi
}

fixture_resource_delete_path() {
	local kind="$1" name="$2"
	case "${kind}" in
		keycloakrealmimport)
			printf '/apis/k8s.keycloak.org/v2alpha1/namespaces/%s/keycloakrealmimports/%s\n' \
				"${FIXTURE_NAMESPACE}" "${name}"
			;;
		keycloak)
			printf '/apis/k8s.keycloak.org/v2alpha1/namespaces/%s/keycloaks/%s\n' \
				"${FIXTURE_NAMESPACE}" "${name}"
			;;
		route)
			printf '/apis/route.openshift.io/v1/namespaces/%s/routes/%s\n' \
				"${FIXTURE_NAMESPACE}" "${name}"
			;;
		deployment)
			printf '/apis/apps/v1/namespaces/%s/deployments/%s\n' \
				"${FIXTURE_NAMESPACE}" "${name}"
			;;
		service|secret|configmap)
			printf '/api/v1/namespaces/%s/%ss/%s\n' \
				"${FIXTURE_NAMESPACE}" "${kind}" "${name}"
			;;
		pvc)
			printf '/api/v1/namespaces/%s/persistentvolumeclaims/%s\n' \
				"${FIXTURE_NAMESPACE}" "${name}"
			;;
		*)
			echo "ERROR: unsupported UID-protected deletion kind ${kind}" >&2
			return 1
			;;
	esac
}

fixture_delete_resource_with_uid() {
	local kind="$1" name="$2" uid="$3" path
	path="$(fixture_resource_delete_path "${kind}" "${name}")" || return 1
	if printf '{"apiVersion":"meta.k8s.io/v1","kind":"DeleteOptions","preconditions":{"uid":"%s"}}\n' \
		"${uid}" | oc delete --raw "${path}" -f - >/dev/null 2>&1; then
		return 0
	fi
	# A resource that disappeared after the ownership read is already clean. A
	# replacement or an API error remains visible and fails cleanup.
	if ! fixture_resource_exists "${kind}" "${name}"; then
		return 0
	fi
	return 1
}

fixture_delete_and_verify_owned_resource() {
	local kind="$1" name="$2"
	fixture_resource_is_owned "${kind}" "${name}" || return 1
	if [[ "${FIXTURE_RESOURCE_OWNED}" != 1 ]]; then
		echo ">> Skipping ${kind} ${name}: absent or not owned by OIDC run ${LABEL_VALUE}" >&2
		return 0
	fi
	fixture_delete_resource_with_uid "${kind}" "${name}" "${FIXTURE_RESOURCE_UID}" || return 1
	fixture_wait_for_resource_absence "${kind}" "${name}"
}

fixture_delete_namespace_with_uid() {
	local uid="$1" path="/api/v1/namespaces/${FIXTURE_NAMESPACE}"
	if printf '{"apiVersion":"meta.k8s.io/v1","kind":"DeleteOptions","preconditions":{"uid":"%s"}}\n' \
		"${uid}" | oc delete --raw "${path}" -f - >/dev/null 2>&1; then
		return 0
	fi
	if ! fixture_namespace_exists; then
		return 0
	fi
	return 1
}

# Delete only the resources this run created (by exact, labelled names) and
# verify they are gone. The namespace is deleted only when this run created
# it.
fixture_delete_owned_resources() {
	local state_dir="$1" status=0
	fixture_load_internal_state "${state_dir}"
	if [[ "${FIXTURE_NAMESPACE_CREATED}" == 1 ]]; then
		if [[ -z "${FIXTURE_NAMESPACE_UID:-}" ]]; then
			echo "ERROR: created fixture namespace has no recorded UID; refusing resource deletion" >&2
			return 1
		fi
		local namespace_status=0
		fixture_namespace_matches_uid || namespace_status=$?
		if (( namespace_status != 0 )); then
			if [[ "${namespace_status}" == 1 ]]; then
				echo ">> Skipping cleanup: created fixture namespace is already absent" >&2
				return 0
			fi
			echo "ERROR: refusing resource cleanup for an unverified fixture namespace" >&2
			return 1
		fi
	fi
	fixture_delete_and_verify_owned_resource keycloakrealmimport "${REALM_IMPORT_NAME}" || status=1
	fixture_delete_and_verify_owned_resource keycloak "${KEYCLOAK_NAME}" || status=1
	fixture_delete_and_verify_owned_resource route "${KEYCLOAK_ROUTE_NAME}" || status=1
	fixture_delete_and_verify_owned_resource deployment "${POSTGRES_NAME}" || status=1
	fixture_delete_and_verify_owned_resource service "${POSTGRES_NAME}" || status=1
	fixture_delete_and_verify_owned_resource pvc "${POSTGRES_NAME}" || status=1
	fixture_delete_and_verify_owned_resource secret "${TLS_SECRET_NAME}" || status=1
	fixture_delete_and_verify_owned_resource secret "${DB_SECRET_NAME}" || status=1
	fixture_delete_and_verify_owned_resource configmap "${FIXTURE_CA_CONFIG_MAP_NAME}" || status=1
	if [[ "${FIXTURE_NAMESPACE_CREATED}" == 1 ]]; then
		if [[ -z "${FIXTURE_NAMESPACE_UID:-}" ]]; then
			echo "ERROR: created fixture namespace has no recorded UID; refusing deletion" >&2
			status=1
		elif [[ "${FIXTURE_NAMESPACE_DELETE_REQUESTED:-0}" == 1 ]]; then
			# A recorded request is only intent, not proof that the API accepted it.
			# Reconcile the live UID before retrying: a rejected request is retryable,
			# while a same-named replacement must never be deleted by this run.
			if fixture_namespace_matches_uid; then
				fixture_delete_namespace_with_uid "${FIXTURE_NAMESPACE_UID}" || status=1
				[[ "${status}" == 0 ]] && fixture_wait_for_namespace_absence || status=1
			else
				namespace_status=$?
				# An already absent namespace is safe; every other result is an
				# identity or API failure and must block cleanup.
				[[ "${namespace_status}" == 1 ]] || status=1
			fi
		else
			if fixture_namespace_matches_uid; then
				# oc delete does not expose Kubernetes DeleteOptions preconditions.
				# Persist the request before deleting so a retry remains safe even
				# when the API accepted the request but verification later failed.
				fixture_write_internal_state "${state_dir}" 1 \
					"${FIXTURE_NAMESPACE_UID}" 1 || status=1
				if [[ "${status}" == 0 ]]; then
					fixture_delete_namespace_with_uid "${FIXTURE_NAMESPACE_UID}" || status=1
					fixture_wait_for_namespace_absence || status=1
				fi
			else
				namespace_status=$?
				# An already absent namespace is safe; every other result is an
				# identity or API failure and must block deletion.
				[[ "${namespace_status}" == 1 ]] || status=1
			fi
		fi
	fi
	return "${status}"
}
