#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Exercise lifecycle boundaries without a cluster: two fresh invocations use
# unique fixture namespaces even with a fixed clock, a label failure after
# namespace creation still deletes the namespace the runner owns, and the
# Keycloak StatefulSet existence check remains before rollout status.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="${ROOT}/odh/scripts/run-odh-oidc.sh"
IDENTITY_VALIDATOR="${ROOT}/odh/scripts/validate-oidc-identity-fixture.py"
ARTIFACT_REDACTOR="${ROOT}/odh/scripts/redact-oidc-artifact.py"
WORKDIR="$(mktemp -d)"
MOCK_BIN="${WORKDIR}/bin"
OC_LOG="${WORKDIR}/oc.log"
RANDOM_COUNTER="${WORKDIR}/random-counter"
KUBECONFIG_FILE="${WORKDIR}/kubeconfig"
IDENTITY_SERVER_PID=""
REAL_OPENSSL="$(command -v openssl)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

cleanup() {
	if [[ -n "${IDENTITY_SERVER_PID}" ]]; then
		kill "${IDENTITY_SERVER_PID}" >/dev/null 2>&1 || true
		wait "${IDENTITY_SERVER_PID}" 2>/dev/null || true
	fi
	rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${MOCK_BIN}"
: > "${OC_LOG}"
printf '0\n' > "${RANDOM_COUNTER}"
: > "${KUBECONFIG_FILE}"

wait_definition_line="$(grep -nFx 'wait_for_keycloak_statefulset() {' "${RUNNER}" | cut -d: -f1)"
wait_invocation_line="$(grep -nFx 'wait_for_keycloak_statefulset' "${RUNNER}" | cut -d: -f1)"
rollout_line="$(grep -nF 'rollout status "statefulset/${KEYCLOAK_NAME}"' "${RUNNER}" | cut -d: -f1)"
if [[ -z "${wait_definition_line}" || -z "${wait_invocation_line}" || -z "${rollout_line}" \
	|| "${wait_invocation_line}" -ge "${rollout_line}" ]] \
	|| ! sed -n "${wait_definition_line},$((wait_invocation_line - 1))p" "${RUNNER}" \
	| grep -Fq 'get "statefulset/${KEYCLOAK_NAME}"'; then
	echo "FAIL: Keycloak StatefulSet must be awaited before rollout status" >&2
	exit 1
fi

identity_definition_line="$(grep -nFx 'validate_identity_fixture() {' "${RUNNER}" | cut -d: -f1)"
identity_invocation_line="$(grep -nFx 'validate_identity_fixture || fail "identity-provider fixture validation failed"' "${RUNNER}" | cut -d: -f1)"
deploy_line="$(grep -nFx 'echo ">> Deploying OpenShell and seeding provider profiles"' "${RUNNER}" | cut -d: -f1)"
if [[ -z "${identity_definition_line}" || -z "${identity_invocation_line}" || -z "${deploy_line}" \
	|| "${identity_invocation_line}" -ge "${deploy_line}" ]] \
	|| ! grep -Fq 'validate-oidc-identity-fixture.py' "${RUNNER}" \
	|| ! grep -Fq 'subject_sha256_12' "${IDENTITY_VALIDATOR}"; then
	echo "FAIL: identity fixture validation must run before the gateway deployment and redact subjects" >&2
	exit 1
fi

# Artifacts must redact both ordinary log fields and quoted JSON response
# fields before they can be retained or printed by the runner.
redaction_raw="${WORKDIR}/redaction.raw"
redaction_result="${WORKDIR}/redaction.result"
cat > "${redaction_raw}" <<'EOF'
authorization: Bearer header-token-secret
{"access_token":"json-access-token-secret","refresh_token":"json-refresh-token-secret","password":"json-password-secret"}
client_secret=json-client-secret
EOF
OIDC_REDACT_ADMIN_PASSWORD='fixture-admin-secret' \
	"${PYTHON_BIN}" "${ARTIFACT_REDACTOR}" "${redaction_raw}" "${redaction_result}"
for secret in header-token-secret json-access-token-secret json-refresh-token-secret json-password-secret json-client-secret fixture-admin-secret; do
	if grep -Fq "${secret}" "${redaction_result}"; then
		echo "FAIL: OIDC artifact redaction retained ${secret}" >&2
		exit 1
	fi
done
if ! grep -Fq '"access_token":[REDACTED]' "${redaction_result}"; then
	echo "FAIL: OIDC artifact redaction did not preserve the JSON token field" >&2
	exit 1
fi

printf '%s\n' \
	'#!/usr/bin/env bash' \
	'printf "%s\n" 1700000000' \
	> "${MOCK_BIN}/date"
chmod +x "${MOCK_BIN}/date"

printf '%s\n' \
	'#!/usr/bin/env bash' \
	'if [[ "$1" == rand && "$2" == -hex ]]; then' \
	'  counter=$(<"${OIDC_TEST_RANDOM_COUNTER}")' \
	'  printf "%08x\n" "${counter}"' \
	'  printf "%s\n" "$((counter + 1))" > "${OIDC_TEST_RANDOM_COUNTER}"' \
	'  exit 0' \
	'fi' \
	'exit 1' \
	> "${MOCK_BIN}/openssl"
chmod +x "${MOCK_BIN}/openssl"

for tool in helm uv; do
	printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${MOCK_BIN}/${tool}"
	chmod +x "${MOCK_BIN}/${tool}"
done

printf '%s\n' \
	'#!/usr/bin/env bash' \
	'printf "%s\n" "$*" >> "${OIDC_TEST_OC_LOG}"' \
	'if [[ "$1" == whoami ]]; then echo test-user; exit 0; fi' \
	'if [[ "$1" == get && "$2" == ingresses.config/cluster ]]; then printf apps.example.test; exit 0; fi' \
	'if [[ "$1" == get && "$2" == namespace ]]; then exit 1; fi' \
	'if [[ "$1" == auth && "$2" == can-i ]]; then echo yes; exit 0; fi' \
	'if [[ "$1" == create && "$2" == namespace ]]; then exit 0; fi' \
	'if [[ "$1" == label && "$2" == namespace ]]; then exit 42; fi' \
	'exit 0' \
	> "${MOCK_BIN}/oc"
chmod +x "${MOCK_BIN}/oc"

run_and_expect_label_failure() {
	local status
	set +e
	PATH="${MOCK_BIN}:${PATH}" \
		KUBECONFIG="${KUBECONFIG_FILE}" \
		OPENSHELL_E2E_RESULTS_DIR="${WORKDIR}/results" \
		OIDC_TEST_OC_LOG="${OC_LOG}" \
		OIDC_TEST_RANDOM_COUNTER="${RANDOM_COUNTER}" \
		"${RUNNER}" >/dev/null 2>&1
	status=$?
	set -e
	if [[ "${status}" == 0 ]]; then
		echo "FAIL: runner unexpectedly succeeded" >&2
		exit 1
	fi
}

run_and_expect_label_failure
run_and_expect_label_failure

namespaces=()
while IFS= read -r namespace; do
	namespaces+=("${namespace}")
done < <(awk '$1 == "create" && $2 == "namespace" { print $3 }' "${OC_LOG}")
if [[ "${#namespaces[@]}" != 2 || "${namespaces[0]}" == "${namespaces[1]}" ]]; then
	echo "FAIL: default OIDC run IDs did not create two distinct namespaces" >&2
	exit 1
fi

for namespace in "${namespaces[@]}"; do
	if ! grep -Fxq "delete namespace ${namespace} --ignore-not-found --wait=false" "${OC_LOG}"; then
		echo "FAIL: cleanup did not delete ${namespace} after label failure" >&2
		exit 1
	fi
done

# RHBK appends "-keycloak-discovery" to the generated Keycloak name. Exercise
# the largest accepted suffix so this derived Service remains DNS-label-safe.
: > "${OC_LOG}"
max_run_id="12345678901234567890123456789"
set +e
PATH="${MOCK_BIN}:${PATH}" \
	KUBECONFIG="${KUBECONFIG_FILE}" \
	OPENSHELL_E2E_RUN_ID="${max_run_id}" \
	OPENSHELL_E2E_RESULTS_DIR="${WORKDIR}/results" \
	OIDC_TEST_OC_LOG="${OC_LOG}" \
	OIDC_TEST_RANDOM_COUNTER="${RANDOM_COUNTER}" \
	"${RUNNER}" >/dev/null 2>&1
status=$?
set -e
if [[ "${status}" == 0 ]] \
	|| ! grep -Fxq "create namespace openshell-oidc-${max_run_id}-rhbk" "${OC_LOG}"; then
	echo "FAIL: maximum DNS-safe OIDC run ID was not accepted" >&2
	exit 1
fi

# The preflight must reject malformed identity claims before the Python gateway
# suite. Exercise both paths against a local token endpoint, then confirm the
# retained evidence fingerprints subjects rather than recording identities or
# credentials.
IDENTITY_PORT_FILE="${WORKDIR}/identity-port"
IDENTITY_DUPLICATE_FILE="${WORKDIR}/duplicate-subject"
"${REAL_OPENSSL}" req -x509 -newkey rsa:2048 -nodes -days 1 \
	-keyout "${WORKDIR}/identity-ca.key" -out "${WORKDIR}/identity-ca.crt" \
	-subj '/CN=identity-test-ca' >/dev/null 2>&1
OIDC_TEST_IDENTITY_PORT_FILE="${IDENTITY_PORT_FILE}" \
OIDC_TEST_IDENTITY_DUPLICATE_FILE="${IDENTITY_DUPLICATE_FILE}" \
	"${PYTHON_BIN}" -u - <<'PY' >"${WORKDIR}/identity-server.log" 2>&1 &
import base64
import json
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def jwt(claims):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b"=").decode()
    return f"{encode({'alg': 'none'})}.{encode(claims)}.signature"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        username = urllib.parse.parse_qs(body)["username"][0]
        subjects = {"admin@test": "subject-admin", "user@test": "subject-user-a", "user-b@test": "subject-user-b"}
        if os.path.exists(os.environ["OIDC_TEST_IDENTITY_DUPLICATE_FILE"]):
            subjects["user-b@test"] = subjects["user@test"]
        roles = ["openshell-user"]
        if username == "admin@test":
            roles.append("openshell-admin")
        payload = json.dumps({"access_token": jwt({
            "iss": "http://127.0.0.1:%s/realms/openshell" % self.server.server_port,
            "sub": subjects[username],
            "realm_access": {"roles": roles},
            "scope": "openid openshell:all",
        })}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.environ["OIDC_TEST_IDENTITY_PORT_FILE"], "w", encoding="utf-8") as output:
    output.write(str(server.server_port))
server.serve_forever()
PY
IDENTITY_SERVER_PID=$!
for _ in $(seq 1 50); do
	[[ -s "${IDENTITY_PORT_FILE}" ]] && break
	sleep 0.1
done
if [[ ! -s "${IDENTITY_PORT_FILE}" ]]; then
	echo "FAIL: identity test endpoint did not start" >&2
	cat "${WORKDIR}/identity-server.log" >&2 || true
	exit 1
fi
identity_issuer="http://127.0.0.1:$(<"${IDENTITY_PORT_FILE}")/realms/openshell"
identity_summary="${WORKDIR}/identity-summary.json"
OIDC_IDENTITY_ISSUER="${identity_issuer}" \
	OIDC_IDENTITY_CA_FILE="${WORKDIR}/identity-ca.crt" \
	OIDC_IDENTITY_ADMIN_PASSWORD='admin-password' \
	OIDC_IDENTITY_USER_PASSWORD='user-password' \
	OIDC_IDENTITY_USER_B_PASSWORD='user-b-password' \
	OIDC_IDENTITY_ADMIN_ROLE='openshell-admin' \
	OIDC_IDENTITY_USER_ROLE='openshell-user' \
	OIDC_IDENTITY_SCOPE='openshell:all' \
	OIDC_IDENTITY_SUMMARY="${identity_summary}" \
	"${PYTHON_BIN}" "${IDENTITY_VALIDATOR}"
"${PYTHON_BIN}" - "${identity_summary}" <<'PY'
import json
import pathlib
import sys

summary = pathlib.Path(sys.argv[1]).read_text()
payload = json.loads(summary)
assert [item["principal"] for item in payload["principals"]] == ["admin", "user-a", "user-b"]
assert "@test" not in summary
assert "password" not in summary
assert all(len(item["subject_sha256_12"]) == 12 for item in payload["principals"])
PY
touch "${IDENTITY_DUPLICATE_FILE}"
set +e
OIDC_IDENTITY_ISSUER="${identity_issuer}" \
	OIDC_IDENTITY_CA_FILE="${WORKDIR}/identity-ca.crt" \
	OIDC_IDENTITY_ADMIN_PASSWORD='admin-password' \
	OIDC_IDENTITY_USER_PASSWORD='user-password' \
	OIDC_IDENTITY_USER_B_PASSWORD='user-b-password' \
	OIDC_IDENTITY_ADMIN_ROLE='openshell-admin' \
	OIDC_IDENTITY_USER_ROLE='openshell-user' \
	OIDC_IDENTITY_SCOPE='openshell:all' \
	OIDC_IDENTITY_SUMMARY="${WORKDIR}/duplicate-summary.json" \
	"${PYTHON_BIN}" "${IDENTITY_VALIDATOR}" >"${WORKDIR}/duplicate.stdout" 2>"${WORKDIR}/duplicate.stderr"
status=$?
set -e
if [[ "${status}" == 0 ]] \
	|| ! grep -Fq 'identity-provider fixture validation failed: token for user-b does not have a distinct subject' "${WORKDIR}/duplicate.stderr" \
	|| [[ -e "${WORKDIR}/duplicate-summary.json" ]]; then
	echo "FAIL: malformed identity fixture did not fail safely" >&2
	exit 1
fi

echo "ODH OIDC runner lifecycle tests passed."
