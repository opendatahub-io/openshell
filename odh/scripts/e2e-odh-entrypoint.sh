#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Container entrypoint for the Shift-Left ODH e2e image. Deploy the selected
# Quay images, run one test tier, and remove that deployment on every exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/openshell-deploy-from-quay.sh"
TEST_SCRIPT="${ROOT}/e2e/rust/tests/odh/run-odh-test-tier.sh"
TIER="${1:-smoke}"

if [[ $# -gt 1 ]]; then
	echo "Usage: $0 [smoke|tier1|tier2|tier3|odh|full]" >&2
	exit 2
fi
case "${TIER}" in
	smoke|tier1|tier2|tier3|odh|full) ;;
	*) echo "ERROR: unknown test tier: ${TIER}" >&2; exit 2 ;;
esac

if [[ -z "${KUBECONFIG:-}" ]]; then
	KUBECONFIG="${ROOT}/.kube/config"
	export KUBECONFIG
fi
if [[ ! -f "${KUBECONFIG}" ]]; then
	echo "ERROR: kubeconfig not found at ${KUBECONFIG}" >&2
	exit 1
fi

cleanup_enabled=0
cleanup() {
	local status=$?
	local cleanup_status=0
	trap - EXIT
	if [[ "${cleanup_enabled}" == 1 ]]; then
		"${DEPLOY_SCRIPT}" teardown --yes || cleanup_status=$?
		if [[ "${cleanup_status}" != 0 ]]; then
			echo "ERROR: OpenShell teardown failed (${cleanup_status})" >&2
			[[ "${status}" != 0 ]] || status="${cleanup_status}"
		fi
	fi
	exit "${status}"
}

if [[ "${OPENSHELL_E2E_DEPLOY_GATEWAY:-1}" != 0 ]]; then
	deploy_args=(deploy --yes)
	if [[ "${OPENSHELL_E2E_REPLACE_EXISTING:-0}" == 1 ]]; then
		deploy_args+=(--replace-existing)
		cleanup_enabled=1
	else
		namespace="${NAMESPACE:-openshell}"
		namespace_resource="$(oc get namespace "${namespace}" --ignore-not-found -o name)"
		[[ -n "${namespace_resource}" ]] || cleanup_enabled=1
	fi
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	"${DEPLOY_SCRIPT}" "${deploy_args[@]}"
	cleanup_enabled=1
	echo ">> Importing example provider profiles"
	"${OPENSHELL_BIN:-openshell}" provider profile import --from "${ROOT}/providers" --global
fi

"${TEST_SCRIPT}" "${TIER}"
