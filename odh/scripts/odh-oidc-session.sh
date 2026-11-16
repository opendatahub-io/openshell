#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Establish the OIDC administrator CLI session against the deployed OpenShift
# gateway and import the example provider profiles the OIDC Python suite
# relies on. Runs after the gateway deployment and the identity preflight:
# with mandatory OIDC authentication the mTLS-registered CLI has no bearer
# token, so a token from the per-run Keycloak fixture is stored the way
# `openshell gateway login` would have stored it, using the shared upstream
# e2e helper. A failure to mint the token is an identity-provider failure; a
# failure of the authenticated CLI call is a gateway failure — the helper's
# errors name which one occurred.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/e2e/support/gateway-common.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"

fail() { echo "ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"
OPENSHELL_BIN="${OPENSHELL_BIN:-openshell}"
command -v "${OPENSHELL_BIN}" >/dev/null 2>&1 || fail "OpenShell CLI not found: ${OPENSHELL_BIN}"
: "${GATEWAY_NAME:?GATEWAY_NAME is required}"
: "${OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT:?OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT is required}"
: "${OPENSHELL_E2E_OIDC_ISSUER:?OPENSHELL_E2E_OIDC_ISSUER is required}"
: "${OPENSHELL_E2E_OIDC_CA_CERT_FILE:?OPENSHELL_E2E_OIDC_CA_CERT_FILE is required}"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
GATEWAY_CONFIG_DIR="${XDG_CONFIG_HOME}/openshell/gateways/${GATEWAY_NAME}"
MTLS_DIR="${GATEWAY_CONFIG_DIR}/mtls"
[[ -r "${MTLS_DIR}/ca.crt" ]] || fail "gateway CA certificate not found at ${MTLS_DIR}/ca.crt (was the gateway deployed?)"

# The shared helper copies ${pki_dir}/ca.crt into the gateway's mtls dir; give
# it a copy so the deploy-written bundle is not cp'd onto itself.
session_pki="$(mktemp -d)"
trap 'rm -rf "${session_pki}"' EXIT
cp "${MTLS_DIR}/ca.crt" "${session_pki}/ca.crt"

register_oidc_admin_session() {
	local username="${OPENSHELL_E2E_OIDC_USERNAME:-admin@test}"
	local password="${OPENSHELL_E2E_OIDC_PASSWORD:?OPENSHELL_E2E_OIDC_PASSWORD is required}"
	local client_id="openshell-cli" token
	local token_url="${OPENSHELL_E2E_OIDC_ISSUER}/protocol/openid-connect/token"

	# Generate the form body in a short-lived Python process and stream it to
	# curl. This preserves '+' and other form characters without putting the
	# password in curl's argument vector or on disk.
	token="$(
		OIDC_TOKEN_URL="${token_url}" OIDC_USERNAME="${username}" \
		OIDC_PASSWORD="${password}" OIDC_CLIENT_ID="${client_id}" \
		"${PYTHON_BIN}" - <<'PY' |
import os
import urllib.parse

print(urllib.parse.urlencode({
    "grant_type": "password",
    "client_id": os.environ["OIDC_CLIENT_ID"],
    "username": os.environ["OIDC_USERNAME"],
    "password": os.environ["OIDC_PASSWORD"],
    "scope": "openid openshell:all",
}), end="")
PY
		curl -sf --data-binary @- "${token_url}" |
		"${PYTHON_BIN}" -c 'import json, sys; print(json.load(sys.stdin)["access_token"])'
	)" || true
	[[ -n "${token}" ]] || fail "could not obtain an admin OIDC token from ${OPENSHELL_E2E_OIDC_ISSUER}"

	mkdir -p "${GATEWAY_CONFIG_DIR}"
	mkdir -p "${GATEWAY_CONFIG_DIR}/mtls"
	cp "${session_pki}/ca.crt" "${GATEWAY_CONFIG_DIR}/mtls/ca.crt"
	cat >"${GATEWAY_CONFIG_DIR}/metadata.json" <<EOF
{
  "name": "${GATEWAY_NAME}",
  "gateway_endpoint": "${OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT}",
  "is_remote": false,
  "gateway_port": 443,
  "auth_mode": "oidc",
  "oidc_issuer": "${OPENSHELL_E2E_OIDC_ISSUER}",
  "oidc_client_id": "${client_id}",
  "oidc_scopes": "openid openshell:all"
}
EOF
	cat >"${GATEWAY_CONFIG_DIR}/oidc_token.json" <<EOF
{
  "access_token": "${token}",
  "issuer": "${OPENSHELL_E2E_OIDC_ISSUER}",
  "client_id": "${client_id}"
}
EOF
	chmod 600 "${GATEWAY_CONFIG_DIR}/oidc_token.json"
	printf '%s' "${GATEWAY_NAME}" >"${XDG_CONFIG_HOME}/openshell/active_gateway"
	if ! "${OPENSHELL_BIN}" provider list-profiles --global --output json >/dev/null 2>&1; then
		fail "the CLI could not make an authenticated call as the OIDC administrator"
	fi
}

# curl verifies the Keycloak Route against the fixture CA; the CLI reaches the
# gateway through the stored mTLS CA.
export SSL_CERT_FILE="${OPENSHELL_E2E_OIDC_CA_CERT_FILE}"
register_oidc_admin_session

e2e_import_example_provider_profiles "${OPENSHELL_BIN}" "${ROOT}"
