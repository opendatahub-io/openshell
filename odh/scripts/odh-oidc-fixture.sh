#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Per-run Red Hat build of Keycloak (RHBK) fixture for the ODH OIDC lane.
# Thin dispatcher: the provisioning, cleanup, and diagnostics concerns live
# in odh/scripts/oidc-fixture/{setup,cleanup,diagnostics}.sh over the shared
# state helpers in common.sh.
#
# setup installs RHBK through OLM when the required CRDs are not already
# served (and never falls back to a local Keycloak), creates a per-run PostgreSQL,
# Keycloak, realm import, passthrough Route, and certificates inside
# OPENSHELL_E2E_RHBK_NAMESPACE (or a run-scoped namespace it creates and
# owns), and waits for Keycloak health and OIDC discovery. Every created
# resource is labelled with the run identifier. It writes a mode-0600
# fixture.env into the state dir with the derived issuer, endpoint, CA
# material, and the temporary OIDC Helm values overlay the gateway
# deployment consumes; the fixture-private run state goes to a separate
# state.env, and no credential is written to either file.
#
# cleanup deletes only the resources this run created (by exact, labelled
# names) plus the fixture namespace when setup created it, and verifies the
# deletions completed. diagnostics captures redacted, per-component cluster
# state for a failed run. The entrypoint decides when each subcommand runs;
# a cleanup failure must not hide the primary result, which is why these
# scripts only report their own status.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/oidc-fixture"
PYTHON_BIN="${PYTHON_BIN:-python3}"
# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"

usage() {
	cat <<'USAGE'
Usage: odh-oidc-fixture.sh <setup|cleanup|diagnostics> --state-dir <dir>

  setup        Create the per-run RHBK Keycloak fixture and write fixture.env.
  cleanup      Delete only the resources owned by this run and verify they are gone.
  diagnostics  Capture redacted per-component diagnostics.

Environment:
  OPENSHELL_E2E_RUN_ID           Required run identifier (DNS-safe, <= 29 chars).
  OPENSHELL_E2E_RHBK_NAMESPACE   Optional existing namespace for RHBK and the
                                 fixture (default: a run-scoped namespace this
                                 script creates, labels, and deletes).
  OPENSHELL_E2E_RHBK_CHANNEL     OLM channel (default: stable-v26.6).
  OPENSHELL_E2E_RHBK_CATALOG_SOURCE
                                 OLM catalog source (default: redhat-operators).
  OPENSHELL_E2E_RETAIN_ON_FAILURE  Retain the fixture when setup fails (1).
  OPENSHELL_E2E_OIDC_ADMIN_PASSWORD
                                 Per-run admin password for setup.
  OPENSHELL_E2E_OIDC_USER_PASSWORD
                                 Per-run user password for setup.
  OPENSHELL_E2E_OIDC_USER_B_PASSWORD
                                 Per-run second-user password for setup.
  OPENSHELL_E2E_OIDC_CI_CLIENT_SECRET
                                 Per-run client-credentials secret for setup.
  OPENSHELL_E2E_RESULTS_DIR      Diagnostics destination (default: results/).
  OPENSHELL_E2E_POSTGRES_IMAGE   PostgreSQL image override (digest-pinned).
  ROUTE_HOST                     Gateway Route host override.
  NAMESPACE, RELEASE             Gateway namespace and Helm release, used by
                                 diagnostics to find the gateway deployment.
USAGE
}

ACTION=""
STATE_DIR=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		setup|cleanup|diagnostics)
			[[ -z "${ACTION}" ]] || fixture_fail "only one action may be given"
			ACTION="$1"
			;;
		--state-dir)
			shift
			[[ $# -gt 0 ]] || fixture_fail "--state-dir requires a value"
			STATE_DIR="$1"
			;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; fixture_fail "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${ACTION}" && -n "${STATE_DIR}" ]] || { usage >&2; exit 2; }
fixture_require_tools
if [[ "${ACTION}" == setup ]]; then
	for credential in \
		OPENSHELL_E2E_OIDC_ADMIN_PASSWORD \
		OPENSHELL_E2E_OIDC_USER_PASSWORD \
		OPENSHELL_E2E_OIDC_USER_B_PASSWORD \
		OPENSHELL_E2E_OIDC_CI_CLIENT_SECRET; do
		[[ -n "${!credential:-}" ]] || fixture_fail "${credential} is required for setup"
	done
fi
if [[ "${ACTION}" != setup ]]; then
	[[ -f "$(fixture_internal_state_path "${STATE_DIR}")" ]] \
		|| fixture_fail "no state.env in ${STATE_DIR}; nothing recorded for this run"
fi

export STATE_DIR PYTHON_BIN
# shellcheck disable=SC1090
source "${LIB_DIR}/${ACTION}.sh"
