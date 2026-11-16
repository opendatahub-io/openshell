#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Cluster-free regression test for the OIDC administrator token request.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_SCRIPT="${SCRIPT_DIR}/../odh-oidc-session.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

MOCK_BIN="${WORKDIR}/bin"
CONFIG_HOME="${WORKDIR}/config"
mkdir -p "${MOCK_BIN}" "${CONFIG_HOME}/openshell/gateways/oidc-session-test/mtls"
printf 'test-ca\n' > "${WORKDIR}/ca.crt"
cp "${WORKDIR}/ca.crt" "${CONFIG_HOME}/openshell/gateways/oidc-session-test/mtls/ca.crt"

cat > "${MOCK_BIN}/curl" <<'CURL'
#!/usr/bin/env bash
cat > "${OIDC_CAPTURE_FILE}"
printf '{"access_token":"stub-token"}\n'
CURL
cat > "${MOCK_BIN}/openshell" <<'CLI'
#!/usr/bin/env bash
exit 0
CLI
chmod +x "${MOCK_BIN}/curl" "${MOCK_BIN}/openshell"

env PATH="${MOCK_BIN}:${PATH}" \
	HOME="${WORKDIR}/home" \
	XDG_CONFIG_HOME="${CONFIG_HOME}" \
	PYTHON_BIN="${PYTHON_BIN:-python3}" \
	OIDC_CAPTURE_FILE="${WORKDIR}/token-request.body" \
	GATEWAY_NAME="oidc-session-test" \
	OPENSHELL_BIN="openshell" \
	OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT="https://gateway.example.test" \
	OPENSHELL_E2E_OIDC_ISSUER="https://keycloak.example.test/realms/openshell" \
	OPENSHELL_E2E_OIDC_CA_CERT_FILE="${WORKDIR}/ca.crt" \
	OPENSHELL_E2E_OIDC_PASSWORD="fixture-password" \
	"${SESSION_SCRIPT}" > "${WORKDIR}/session.log" 2>&1

python3 - "${WORKDIR}/token-request.body" <<'PY'
from pathlib import Path
import sys

expected = (
    b"grant_type=password&client_id=openshell-cli&username=admin%40test"
    b"&password=fixture-password&scope=openid+openshell%3Aall"
)
actual = Path(sys.argv[1]).read_bytes()
if actual != expected:
    raise SystemExit("OIDC token form body differs from the expected exact bytes")
PY

grep -Fq '"access_token": "stub-token"' \
	"${CONFIG_HOME}/openshell/gateways/oidc-session-test/oidc_token.json" || {
	echo "FAIL: session did not store the token returned by Keycloak" >&2
	cat "${WORKDIR}/session.log" >&2
	exit 1
}

echo "ok: OIDC administrator token request has no trailing scope whitespace"
