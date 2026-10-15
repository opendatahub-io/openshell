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
OIDC_SCRIPT="${SCRIPT_DIR}/run-odh-oidc.sh"
TIER="${1:-smoke}"

if [[ $# -gt 1 ]]; then
	echo "Usage: $0 [smoke|tier1|tier2|tier3|odh|full|oidc]" >&2
	exit 2
fi
case "${TIER}" in
	smoke|tier1|tier2|tier3|odh|full|oidc) ;;
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

# OIDC owns two independently cleaned deployments: its RHBK fixture namespace
# and the OpenShell namespace. Keep it outside the Rust-tier lifecycle below.
if [[ "${TIER}" == oidc ]]; then
	exec "${OIDC_SCRIPT}"
fi

cleanup_enabled=0
child_pid=""
deploy_state_dir=""
cleanup() {
	local status=$?
	local cleanup_status=0
	trap - EXIT
	if [[ "${cleanup_enabled}" == 1 && -f "${deploy_state_dir}/namespace" ]]; then
		teardown_args=(teardown --yes)
		if [[ ! -f "${deploy_state_dir}/gateway" ]]; then
			teardown_args+=(--keep-local-gateway)
		fi
		"${DEPLOY_SCRIPT}" "${teardown_args[@]}" || cleanup_status=$?
		if [[ "${cleanup_status}" != 0 ]]; then
			echo "ERROR: OpenShell teardown failed (${cleanup_status})" >&2
			[[ "${status}" != 0 ]] || status="${cleanup_status}"
		fi
	fi
	if [[ -n "${deploy_state_dir}" ]]; then
		rm -rf "${deploy_state_dir}"
	fi
	exit "${status}"
}
stop_child() {
	local signal="$1" code="$2"
	trap '' INT TERM
	if [[ -n "${child_pid}" ]]; then
		kill -"${signal}" "${child_pid}" 2>/dev/null || true
		wait "${child_pid}" || true
	fi
	exit "${code}"
}
run_child() {
	local status=0
	"$@" &
	child_pid=$!
	wait "${child_pid}" || status=$?
	child_pid=""
	return "${status}"
}

trap cleanup EXIT
# Bash background jobs inherit SIGINT ignored; use TERM to stop the child.
trap 'stop_child TERM 130' INT
trap 'stop_child TERM 143' TERM

if [[ "${OPENSHELL_E2E_DEPLOY_GATEWAY:-1}" != 0 ]]; then
	deploy_args=(deploy --yes)
	if [[ "${OPENSHELL_E2E_REPLACE_EXISTING:-0}" == 1 ]]; then
		deploy_args+=(--replace-existing)
	fi
	deploy_state_dir="$(mktemp -d)"
	export OPENSHELL_E2E_DEPLOY_STATE_DIR="${deploy_state_dir}"
	cleanup_enabled=1
	run_child "${DEPLOY_SCRIPT}" "${deploy_args[@]}"
	echo ">> Importing example provider profiles"
	run_child "${OPENSHELL_BIN:-openshell}" provider profile import --from "${ROOT}/providers" --global
fi

run_child "${TEST_SCRIPT}" "${TIER}"
