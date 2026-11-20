#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Cluster-free tests for the ODH OIDC lane. Covers the runner's explicit
# endpoint/issuer contract (no local Docker fallback), the separation between
# the normal Python and OIDC modes, the fixture's run-id, ownership-label,
# retention-scrubbing, and cleanup-verification behavior, the identity
# preflight (including IdP classification of scope and client-credential
# failures), the per-component diagnostics capture, artifact redaction, and
# the entrypoint's OIDC lifecycle: run-scoped namespace/release isolation,
# report-path registration and merge order, cleanup after a deployment
# failure, a cleanup failure preserving the primary result, and failure
# retention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RUNNER="${SCRIPT_DIR}/../run-python-e2e.sh"
ENTRYPOINT="${SCRIPT_DIR}/../e2e-odh-entrypoint.sh"
FIXTURE="${SCRIPT_DIR}/../odh-oidc-fixture.sh"
FIXTURE_SETUP="${SCRIPT_DIR}/../oidc-fixture/setup.sh"
TLS_GENERATOR="${SCRIPT_DIR}/../generate-oidc-tls-material.sh"
IDENTITY_VALIDATOR="${SCRIPT_DIR}/../validate-oidc-identity-fixture.py"

WORKDIR="$(mktemp -d)"
cleanup() {
	if [[ -n "${IDENTITY_SERVER_PID:-}" ]]; then
		kill "${IDENTITY_SERVER_PID}" >/dev/null 2>&1 || true
		wait "${IDENTITY_SERVER_PID}" 2>/dev/null || true
	fi
	rm -rf "${WORKDIR}"
}
trap cleanup EXIT

PYTHON_TEST_BIN="${PYTHON_BIN:-${ROOT}/.venv/bin/python}"
if [[ ! -x "${PYTHON_TEST_BIN}" ]]; then
	PYTHON_TEST_BIN="$(command -v python3)"
fi
if ! PYTHONPATH="${ROOT}/python:${ROOT}/odh/scripts" "${PYTHON_TEST_BIN}" -c 'import pytest, tomllib, openshell, pytest_odh_gates' >/dev/null 2>&1; then
	echo "SKIP: no Python E2E test interpreter available (PYTHON_BIN=${PYTHON_TEST_BIN})" >&2
	exit 0
fi

assert_runner_rejects() {
	local case_name="$1" expected="$2"; shift 2
	local log_file="${WORKDIR}/${case_name}.log"
	echo ">> the OIDC runner rejects ${case_name}"
	local status
	if env "$@" "${RUNNER}" --oidc "${WORKDIR}/${case_name}.xml" >"${log_file}" 2>&1; then
		echo "FAIL: OIDC runner accepted ${case_name}" >&2
		exit 1
	else
		status=$?
	fi
	[[ "${status}" == 2 ]] || {
		echo "FAIL: ${case_name} exited ${status}, expected 2" >&2
		cat "${log_file}" >&2
		exit 1
	}
	grep -q "${expected}" "${log_file}" || {
		echo "FAIL: ${case_name} rejection did not explain the requirement" >&2
		cat "${log_file}" >&2
		exit 1
	}
	echo "ok: OIDC runner rejects ${case_name}"
}

assert_runner_rejects missing-endpoint \
	'OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT is required' \
	-u OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT -u OPENSHELL_GATEWAY_ENDPOINT \
	-u OPENSHELL_E2E_OIDC OPENSHELL_E2E_DEPLOY_GATEWAY=1 \
	OPENSHELL_E2E_OIDC_ISSUER="https://kc.invalid/realms/openshell"
grep -q 'refusing to derive a local endpoint' "${WORKDIR}/missing-endpoint.log" || {
	echo "FAIL: missing endpoint rejection did not rule out a local fallback" >&2
	cat "${WORKDIR}/missing-endpoint.log" >&2
	exit 1
}

assert_runner_rejects missing-issuer \
	'OPENSHELL_E2E_OIDC_ISSUER is required' \
	-u OPENSHELL_E2E_OIDC_ISSUER -u OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT \
	-u OPENSHELL_GATEWAY_ENDPOINT -u OPENSHELL_E2E_OIDC \
	OPENSHELL_E2E_DEPLOY_GATEWAY=1 OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT="https://gw.invalid"

assert_runner_rejects plaintext-endpoint \
	'must be an HTTPS OpenShift Route endpoint' \
	OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT="http://127.0.0.1:8080" \
	OPENSHELL_E2E_OIDC_ISSUER="https://kc.invalid/realms/openshell"

# A fake interpreter records the environment and arguments it is invoked with
# and emulates pytest well enough for the runner's post-processing. The
# emulated failure status applies only to the --junitxml run, never to the
# collection or post-processing invocations.
FAKE_PYTHON="${WORKDIR}/fake-python.sh"
CAPTURE_DIR="${WORKDIR}/capture"
mkdir -p "${CAPTURE_DIR}"
cat > "${FAKE_PYTHON}" <<SH
#!/usr/bin/env bash
set -euo pipefail
# Script invocations (strip-skipped-testcases.py, redact-oidc-artifact.py)
# run with the real interpreter so the runner's post-processing is exercised.
if [[ "\${1:-}" == *.py ]]; then
	if [[ "\${1}" == *redact-oidc-artifact.py* && "\${FAKE_REDACT_FAIL_ON:-0}" != 0 ]]; then
		redact_count=0
		[[ -f "${CAPTURE_DIR}/redact-count" ]] && redact_count="\$(<"${CAPTURE_DIR}/redact-count")"
		redact_count=\$((redact_count + 1))
		printf '%s\n' "\${redact_count}" > "${CAPTURE_DIR}/redact-count"
		if [[ "\${redact_count}" == "\${FAKE_REDACT_FAIL_ON}" ]]; then
			exit "\${FAKE_REDACT_STATUS:-23}"
		fi
	fi
	exec "\${PYTHON_BIN:-python3}" "\$@"
fi
if [[ "\${1:-}" == "-" ]]; then
	exec "\${PYTHON_BIN:-python3}" "\$@"
fi
if [[ "\${1:-}" == "-m" ]]; then
	{
		printf 'OIDC=%s\\n' "\${OPENSHELL_E2E_OIDC:-}"
		printf 'SCOPES=%s\\n' "\${OPENSHELL_E2E_OIDC_SCOPES:-}"
		printf 'ENDPOINT=%s\\n' "\${OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT:-}"
		printf 'SSL_CERT_FILE=%s\\n' "\${SSL_CERT_FILE:-}"
	} > "${CAPTURE_DIR}/env"
	printf '%s\\n' "\$*" > "${CAPTURE_DIR}/args"
fi
saw_junit=0
while [[ \$# -gt 0 ]]; do
	case "\$1" in
		--junitxml)
			printf '<testsuite name="oidc" tests="1"><testcase name="passes"/></testsuite>\\n' > "\$2"
			echo 'authorization: Bearer fake-pytest-token'
			saw_junit=1
			shift 2
			;;
		*) shift ;;
	esac
done
if [[ "\${saw_junit}" == 1 ]]; then
	exit "\${FAKE_PYTEST_STATUS:-0}"
fi
exit 0
SH
chmod +x "${FAKE_PYTHON}"

echo ">> the OIDC runner targets both OIDC directories with OIDC enabled and no xdist"
OIDC_CA_FILE="${WORKDIR}/oidc-ca.crt"
printf 'fixture-ca\n' > "${OIDC_CA_FILE}"
OIDC_REPORT="${WORKDIR}/oidc-report.xml"
PYTHON_BIN="${PYTHON_TEST_BIN}" \
OPENSHELL_E2E_PYTHON="${FAKE_PYTHON}" \
OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT="https://gw-oidc.example.test" \
OPENSHELL_E2E_OIDC_ISSUER="https://kc-oidc.example.test/realms/openshell" \
OPENSHELL_E2E_OIDC_CA_CERT_FILE="${OIDC_CA_FILE}" \
"${RUNNER}" --oidc "${OIDC_REPORT}" > "${WORKDIR}/oidc-run.log" 2>&1
grep -qx 'OIDC=1' "${CAPTURE_DIR}/env" || {
	echo "FAIL: OIDC run did not enable OPENSHELL_E2E_OIDC" >&2
	cat "${CAPTURE_DIR}/env" >&2
	exit 1
}
grep -qx 'SCOPES=1' "${CAPTURE_DIR}/env" || {
	echo "FAIL: OIDC run did not enable scope enforcement" >&2
	cat "${CAPTURE_DIR}/env" >&2
	exit 1
}
grep -qx 'ENDPOINT=https://gw-oidc.example.test' "${CAPTURE_DIR}/env" || {
	echo "FAIL: OIDC run did not pass the endpoint through unchanged" >&2
	cat "${CAPTURE_DIR}/env" >&2
	exit 1
}
grep -qx "SSL_CERT_FILE=${OIDC_CA_FILE}" "${CAPTURE_DIR}/env" || {
	echo "FAIL: OIDC run did not trust the fixture CA" >&2
	cat "${CAPTURE_DIR}/env" >&2
	exit 1
}
grep -qw 'e2e/python/oidc' "${CAPTURE_DIR}/args" || {
	echo "FAIL: OIDC run did not target the OIDC suite directory" >&2
	cat "${CAPTURE_DIR}/args" >&2
	exit 1
}
grep -qw 'odh/tests/oidc' "${CAPTURE_DIR}/args" || {
	echo "FAIL: OIDC run did not target the fork-only multi-user suite" >&2
	cat "${CAPTURE_DIR}/args" >&2
	exit 1
}
if grep -q ' -n ' "${CAPTURE_DIR}/args"; then
	echo "FAIL: OIDC run used xdist workers" >&2
	cat "${CAPTURE_DIR}/args" >&2
	exit 1
fi
grep -q -- '-p no:xdist' "${CAPTURE_DIR}/args" || {
	echo "FAIL: OIDC run did not disable xdist explicitly" >&2
	cat "${CAPTURE_DIR}/args" >&2
	exit 1
}
[[ -f "${OIDC_REPORT}" ]] || {
	echo "FAIL: OIDC run did not produce a JUnit report" >&2
	exit 1
}
[[ -f "${WORKDIR}/oidc-manual-pytest.log" ]] || {
	echo "FAIL: OIDC run did not capture the pytest output log" >&2
	exit 1
}
if grep -Fq 'fake-pytest-token' "${WORKDIR}/oidc-manual-pytest.log"; then
	echo "FAIL: the captured pytest log was not redacted" >&2
	exit 1
fi
grep -Fq 'Bearer [REDACTED]' "${WORKDIR}/oidc-manual-pytest.log" || {
	echo "FAIL: the captured pytest log lost its redacted bearer marker" >&2
	exit 1
}
if grep -Fq 'fake-pytest-token' "${WORKDIR}/oidc-run.log"; then
	echo "FAIL: raw pytest output reached the runner stdout" >&2
	exit 1
fi
grep -Fq 'Bearer [REDACTED]' "${WORKDIR}/oidc-run.log" || {
	echo "FAIL: runner stdout did not contain redacted pytest output" >&2
	exit 1
}
echo "ok: OIDC runner separates the OIDC suite from the normal lane"

echo ">> OIDC artifact redaction fails closed and preserves pytest status"
REDACTION_FAIL_REPORT="${WORKDIR}/redaction-fail-report.xml"
rm -f "${CAPTURE_DIR}/redact-count"
set +e
PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_PYTHON="${FAKE_PYTHON}" \
	FAKE_REDACT_FAIL_ON=1 FAKE_REDACT_STATUS=23 \
	OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT="https://gw-oidc.example.test" \
	OPENSHELL_E2E_OIDC_ISSUER="https://kc-oidc.example.test/realms/openshell" \
	OPENSHELL_E2E_OIDC_CA_CERT_FILE="${OIDC_CA_FILE}" \
	"${RUNNER}" --oidc "${REDACTION_FAIL_REPORT}" > "${WORKDIR}/redaction-fail-report.log" 2>&1
redaction_fail_status=$?
set -e
[[ "${redaction_fail_status}" == 23 ]] || {
	echo "FAIL: XML redaction failure did not propagate its status" >&2
	cat "${WORKDIR}/redaction-fail-report.log" >&2
	exit 1
}
[[ ! -e "${REDACTION_FAIL_REPORT}" && ! -e "${REDACTION_FAIL_REPORT}.redacted" ]] || {
	echo "FAIL: unredacted JUnit report survived a redaction failure" >&2
	exit 1
}
echo "ok: XML redaction fails closed"

echo ">> pytest-log redaction also fails closed"
REDACTION_FAIL_LOG_REPORT="${WORKDIR}/redaction-fail-log-report.xml"
rm -f "${CAPTURE_DIR}/redact-count"
set +e
PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_PYTHON="${FAKE_PYTHON}" \
	FAKE_REDACT_FAIL_ON=2 FAKE_REDACT_STATUS=24 \
	OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT="https://gw-oidc.example.test" \
	OPENSHELL_E2E_OIDC_ISSUER="https://kc-oidc.example.test/realms/openshell" \
	OPENSHELL_E2E_OIDC_CA_CERT_FILE="${OIDC_CA_FILE}" \
	"${RUNNER}" --oidc "${REDACTION_FAIL_LOG_REPORT}" > "${WORKDIR}/redaction-fail-log.log" 2>&1
redaction_fail_log_status=$?
set -e
[[ "${redaction_fail_log_status}" == 24 ]] || {
	echo "FAIL: pytest-log redaction failure did not propagate its status" >&2
	cat "${WORKDIR}/redaction-fail-log.log" >&2
	exit 1
}
[[ -f "${REDACTION_FAIL_LOG_REPORT}" ]] || {
	echo "FAIL: successful JUnit redaction was removed by a pytest-log failure" >&2
	exit 1
}
[[ ! -e "${WORKDIR}/oidc-manual-pytest.log" && ! -e "${WORKDIR}/oidc-manual-pytest.log.redacted" ]] || {
	echo "FAIL: unredacted pytest log survived a redaction failure" >&2
	exit 1
}
echo "ok: pytest-log redaction fails closed"

echo ">> the fixture TLS generator produces a SAN certificate and 0600 keys"
TLS_DIR="${WORKDIR}/tls"
bash "${TLS_GENERATOR}" "${TLS_DIR}" "kc-oidc.example.test"
[[ -f "${TLS_DIR}/keycloak-ca.crt" && -f "${TLS_DIR}/tls.crt" ]] || {
	echo "FAIL: TLS generator did not produce certificates" >&2
	exit 1
}
openssl x509 -in "${TLS_DIR}/tls.crt" -noout -text | grep -q 'DNS:kc-oidc.example.test' || {
	echo "FAIL: TLS certificate lacks the Route hostname SAN" >&2
	exit 1
}
[[ -z "$(find "${TLS_DIR}" -name '*.key' -not -perm 600)" ]] || {
	echo "FAIL: TLS generator left private keys wider than 0600" >&2
	exit 1
}
echo "ok: fixture TLS material"

# The identity preflight is exercised against a local token endpoint: the
# success path must write fingerprinted evidence, a duplicate subject must
# fail without writing the summary, and scope / client-credential contract
# failures must be reported as identity-provider failures.
IDENTITY_PORT_FILE="${WORKDIR}/identity-port"
IDENTITY_DUPLICATE_FILE="${WORKDIR}/duplicate-subject"
IDENTITY_MISSING_SCOPE_FILE="${WORKDIR}/missing-scope"
IDENTITY_BAD_CI_AUDIENCE_FILE="${WORKDIR}/bad-ci-audience"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
	-keyout "${WORKDIR}/identity-ca.key" -out "${WORKDIR}/identity-ca.crt" \
	-subj '/CN=identity-test-ca' >/dev/null 2>&1
OIDC_TEST_IDENTITY_PORT_FILE="${IDENTITY_PORT_FILE}" \
OIDC_TEST_IDENTITY_DUPLICATE_FILE="${IDENTITY_DUPLICATE_FILE}" \
OIDC_TEST_IDENTITY_MISSING_SCOPE_FILE="${IDENTITY_MISSING_SCOPE_FILE}" \
OIDC_TEST_IDENTITY_BAD_CI_AUDIENCE_FILE="${IDENTITY_BAD_CI_AUDIENCE_FILE}" \
	"${PYTHON_TEST_BIN}" -u - <<'PY' >"${WORKDIR}/identity-server.log" 2>&1 &
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
        form = urllib.parse.parse_qs(body)
        if form.get("grant_type", [""])[0] == "client_credentials":
            claims = {
                "iss": "http://127.0.0.1:%s/realms/openshell" % self.server.server_port,
                "sub": "subject-ci-client",
                "aud": [] if os.path.exists(os.environ["OIDC_TEST_IDENTITY_BAD_CI_AUDIENCE_FILE"]) else ["openshell-cli"],
                "realm_access": {"roles": ["openshell-user"]},
                "scope": "openid openshell:all",
            }
        else:
            username = form["username"][0]
            subjects = {"admin@test": "subject-admin", "user@test": "subject-user-a", "user-b@test": "subject-user-b"}
            if os.path.exists(os.environ["OIDC_TEST_IDENTITY_DUPLICATE_FILE"]):
                subjects["user-b@test"] = subjects["user@test"]
            roles = ["openshell-user"]
            if username == "admin@test":
                roles.append("openshell-admin")
            scope = form.get("scope", ["openid"])[0]
            if os.path.exists(os.environ["OIDC_TEST_IDENTITY_MISSING_SCOPE_FILE"]) and "sandbox" in scope:
                scope = "openid sandbox:read"
            claims = {
                "iss": "http://127.0.0.1:%s/realms/openshell" % self.server.server_port,
                "sub": subjects[username],
                "realm_access": {"roles": roles},
                # Reflect the requested optional scopes so the scoped-token
                # contract check sees exactly what the caller asked for.
                "scope": scope,
            }
        payload = json.dumps({"access_token": jwt(claims)}).encode()
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

run_identity_validator() {
	local summary="$1"
	shift
	OIDC_IDENTITY_ISSUER="${identity_issuer}" \
		OIDC_IDENTITY_CA_FILE="${WORKDIR}/identity-ca.crt" \
		OIDC_IDENTITY_ADMIN_PASSWORD='admin-password' \
		OIDC_IDENTITY_USER_PASSWORD='user-password' \
		OIDC_IDENTITY_USER_B_PASSWORD='user-b-password' \
		OIDC_IDENTITY_CI_CLIENT_SECRET='ci-client-secret' \
		OIDC_IDENTITY_ADMIN_ROLE='openshell-admin' \
		OIDC_IDENTITY_USER_ROLE='openshell-user' \
		OIDC_IDENTITY_SCOPE='openshell:all' \
		OIDC_IDENTITY_SUMMARY="${summary}" \
		"$@" "${PYTHON_TEST_BIN}" "${IDENTITY_VALIDATOR}"
}

echo ">> the identity preflight validates subjects, roles, scopes, and the CI client"
run_identity_validator "${identity_summary}"
"${PYTHON_TEST_BIN}" - "${identity_summary}" <<'PY'
import json
import pathlib
import sys

summary = pathlib.Path(sys.argv[1]).read_text()
payload = json.loads(summary)
assert [item["principal"] for item in payload["principals"]] == [
    "admin",
    "user-a",
    "user-b",
    "ci-client",
]
assert "@test" not in summary
assert "password" not in summary
assert all(len(item["subject_sha256_12"]) == 12 for item in payload["principals"])
PY
echo "ok: identity preflight success path"

expect_identity_failure() {
	local label="$1" marker="$2" expected="$3" summary="$4"
	touch "${marker}"
	if run_identity_validator "${summary}" >"${WORKDIR}/identity-failure.stdout" 2>"${WORKDIR}/identity-failure.stderr"; then
		echo "FAIL: ${label} unexpectedly validated" >&2
		exit 1
	fi
	grep -Fq "identity-provider fixture validation failed: ${expected}" "${WORKDIR}/identity-failure.stderr" || {
		echo "FAIL: ${label} was not classified as an identity-provider failure" >&2
		cat "${WORKDIR}/identity-failure.stderr" >&2
		exit 1
	}
	[[ ! -e "${summary}" ]] || {
		echo "FAIL: ${label} still wrote evidence" >&2
		exit 1
	}
	rm -f "${marker}"
	echo "ok: ${label} classified as an identity-provider failure"
}

expect_identity_failure \
	"a duplicate subject" \
	"${IDENTITY_DUPLICATE_FILE}" \
	"token for user-b does not have a distinct subject" \
	"${WORKDIR}/duplicate-summary.json"

expect_identity_failure \
	"a missing optional scope" \
	"${IDENTITY_MISSING_SCOPE_FILE}" \
	"scoped admin token is missing optional scope sandbox:write" \
	"${WORKDIR}/missing-scope-summary.json"

expect_identity_failure \
	"a CI client without the gateway audience" \
	"${IDENTITY_BAD_CI_AUDIENCE_FILE}" \
	"token for ci-client is missing the openshell-cli audience" \
	"${WORKDIR}/bad-ci-audience-summary.json"

kill "${IDENTITY_SERVER_PID}" >/dev/null 2>&1 || true
wait "${IDENTITY_SERVER_PID}" 2>/dev/null || true
IDENTITY_SERVER_PID=""
echo "ok: identity preflight failure paths"

# ── Fixture behavior with shared mocked oc ──────────────────────────────────

# The same mock and fixture runner are reused by all lifecycle scenarios.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oidc-test-lib.sh"
oidc_test_init
echo ">> no credential is ever written to the state directory"
if grep -q 'OIDC_IDENTITY_.*_PASSWORD' "${FIXTURE_SETUP}"; then
	echo "FAIL: the operational environment would carry a password" >&2
	exit 1
fi
grep -Fq -- '--from-file=password=<(printf' "${FIXTURE_SETUP}" || {
	echo "FAIL: the database password is not passed through a file descriptor" >&2
	exit 1
}
echo "ok: state directory carries no credential"

echo ">> the fixture resolves the realm from the repository-level scripts directory"
[[ -f "${ROOT}/scripts/keycloak-realm.json" ]] || {
	echo "FAIL: repository realm fixture is missing" >&2
	exit 1
}
grep -Fq "REALM_FILE=\"\${FIXTURE_ROOT}/../scripts/keycloak-realm.json\"" "${FIXTURE_SETUP}" || {
	echo "FAIL: fixture setup does not use the repository-level realm fixture" >&2
	exit 1
}
[[ ! -e "${ROOT}/odh/scripts/keycloak-realm.json" ]] || {
	echo "FAIL: the test unexpectedly relies on a duplicate ODH realm fixture" >&2
	exit 1
}
echo "ok: realm fixture path"
[[ "$(grep -cF 'apiVersion: k8s.keycloak.org/v2alpha1' "${FIXTURE_SETUP}")" == 1 ]] || {
	echo "FAIL: Keycloak manifest does not use the compatible v2alpha1 API" >&2
	exit 1
}
grep -Fq '"apiVersion": "k8s.keycloak.org/v2alpha1"' "${FIXTURE_SETUP}" || {
	echo "FAIL: KeycloakRealmImport manifest does not use the compatible v2alpha1 API" >&2
	exit 1
}
if grep -Fq 'v2beta1' "${FIXTURE_SETUP}"; then
	echo "FAIL: fixture setup still references the v2beta1 Keycloak API" >&2
	exit 1
fi
echo "ok: RHBK API version compatibility"
grep -Fq 'kind: OperatorGroup' "${FIXTURE_SETUP}" || {
	echo "FAIL: fixture setup does not install an RHBK OperatorGroup" >&2
	exit 1
}
grep -Fq 'kind: Subscription' "${FIXTURE_SETUP}" || {
	echo "FAIL: fixture setup does not install an RHBK Subscription" >&2
	exit 1
}
grep -Fq 'name: rhbk-operator' "${FIXTURE_SETUP}" || {
	echo "FAIL: fixture setup does not target the RHBK operator package" >&2
	exit 1
}
echo "ok: fixture installs RHBK through OLM when CRDs are absent"

echo ">> missing RHBK CRDs trigger an OLM installation request"
CRD_STATE="${WORKDIR}/crd-state"
: > "${APPLY_MANIFESTS}"
set +e
run_fixture_setup "${CRD_STATE}" \
	OPENSHELL_E2E_RUN_ID="crdinstall1" \
	OC_MOCK_CRD_STATUS=1 \
	OC_MOCK_ROLLOUT_STATUS=42
crd_install_status=$?
set -e
[[ "${crd_install_status}" != 0 ]] || {
	echo "FAIL: CRD-missing fixture unexpectedly succeeded" >&2
	exit 1
}
grep -Fq 'kind: OperatorGroup' "${APPLY_MANIFESTS}" || {
	echo "FAIL: missing-CRD path did not apply an OperatorGroup" >&2
	exit 1
}
grep -Fq 'kind: Subscription' "${APPLY_MANIFESTS}" || {
	echo "FAIL: missing-CRD path did not apply an RHBK Subscription" >&2
	exit 1
}
echo "ok: missing RHBK CRDs request OLM installation"

echo ">> caller-owned RHBK namespaces reject missing CRDs before OLM mutation"
CALLER_CRD_STATE="${WORKDIR}/caller-crd-state"
: > "${APPLY_MANIFESTS}"
set +e
run_fixture_setup "${CALLER_CRD_STATE}" \
	OPENSHELL_E2E_RUN_ID="callercrd1" \
	OPENSHELL_E2E_RHBK_NAMESPACE="shared-rhbk" \
	OPENSHELL_E2E_RETAIN_ON_FAILURE=1 \
	OC_MOCK_NAMESPACE_EXISTS=0 \
	OC_MOCK_CRD_STATUS=1
caller_crd_status=$?
set -e
[[ "${caller_crd_status}" != 0 ]] || {
	echo "FAIL: caller-owned namespace accepted missing RHBK CRDs" >&2
	exit 1
}
grep -Fq 'refusing to install OLM resources in caller-owned namespace' "${WORKDIR}/fixture-run.log" || {
	echo "FAIL: caller-owned missing-CRD failure did not explain the safety boundary" >&2
	cat "${WORKDIR}/fixture-run.log" >&2
	exit 1
}
if grep -Eq 'kind: (OperatorGroup|Subscription)' "${APPLY_MANIFESTS}"; then
	echo "FAIL: caller-owned missing-CRD path mutated OLM resources" >&2
	cat "${APPLY_MANIFESTS}" >&2
	exit 1
fi
echo "ok: caller-owned RHBK namespaces are not mutated by OLM setup"

echo ">> successful fixture setup leaves cleanup to the entrypoint"
setup_success_line="$(grep -nF "if [[ \"\${status}\" == 0 ]]; then" "${FIXTURE_SETUP}" | head -1 | cut -d: -f1)"
setup_cleanup_call_line="$(grep -nF "fixture_delete_owned_resources \"\${STATE_DIR}\"" "${FIXTURE_SETUP}" | head -1 | cut -d: -f1)"
[[ -n "${setup_success_line}" && -n "${setup_cleanup_call_line}" && "${setup_success_line}" -lt "${setup_cleanup_call_line}" ]] || {
	echo "FAIL: setup still cleans a successful fixture from its EXIT trap" >&2
	exit 1
}
echo "ok: successful fixture setup remains live"

echo ">> a failed realm-import deletion bypasses retention and retries cleanup"
IMPORT_DELETE_STATE="${WORKDIR}/import-delete-state"
: > "${OC_LOG}"
set +e
run_fixture_setup "${IMPORT_DELETE_STATE}" \
	OPENSHELL_E2E_RUN_ID="importdelete1" \
	OPENSHELL_E2E_RETAIN_ON_FAILURE=1 \
	OC_MOCK_REALM_IMPORT_DELETE_STATUS=19
import_delete_status=$?
set -e
[[ "${import_delete_status}" != 0 ]] || {
	echo "FAIL: realm-import deletion failure unexpectedly succeeded" >&2
	exit 1
}
grep -q 'bypassing retention' "${WORKDIR}/fixture-run.log" || {
	echo "FAIL: realm-import deletion failure did not bypass retention" >&2
	cat "${WORKDIR}/fixture-run.log" >&2
	exit 1
}
[[ "$(grep -c 'delete keycloakrealmimport openshell-oidc-importdelete1-realm' "${OC_LOG}")" -ge 2 ]] || {
	echo "FAIL: realm-import cleanup was not retried after deletion failure" >&2
	cat "${OC_LOG}" >&2
	exit 1
}
[[ -f "${IMPORT_DELETE_STATE}/state.env" ]] || {
	echo "FAIL: failed realm-import cleanup did not preserve retry state" >&2
	exit 1
}
echo "ok: realm-import deletion failure is retryable and never retained"

echo ">> a retained setup failure leaves no credential or private key behind"
RETAIN_STATE="${WORKDIR}/retain-state"
: > "${OC_LOG}"
set +e
run_fixture_setup "${RETAIN_STATE}" \
	OPENSHELL_E2E_RUN_ID="retainrun1" \
	OPENSHELL_E2E_RETAIN_ON_FAILURE=1 \
	OC_MOCK_APPLY_STATUS=7
retain_status=$?
set -e
[[ "${retain_status}" != 0 ]] || {
	echo "FAIL: a failing apply unexpectedly succeeded" >&2
	exit 1
}
for forbidden in ca.key tls.key db-password db-username; do
	[[ ! -e "${RETAIN_STATE}/${forbidden}" ]] || {
		echo "FAIL: retained state still contains ${forbidden}" >&2
		exit 1
	}
done
if grep -Fq "delete namespace" "${OC_LOG}"; then
	echo "FAIL: the retained fixture was cleaned up despite retention" >&2
	exit 1
fi
[[ -f "${RETAIN_STATE}/state.env" ]] || {
	echo "FAIL: the internal run state was not recorded" >&2
	exit 1
}
echo "ok: retention keeps no credentials"

echo ">> a namespace-label failure after creation still cleans the owned namespace"
LABEL_STATE="${WORKDIR}/label-state"
: > "${OC_LOG}"
set +e
run_fixture_setup "${LABEL_STATE}" \
	OPENSHELL_E2E_RUN_ID="labelfail42" \
	OC_MOCK_LABEL_STATUS=42
label_status=$?
set -e
[[ "${label_status}" != 0 ]] || {
	echo "FAIL: namespace-label failure unexpectedly succeeded" >&2
	exit 1
}
grep -Fxq "delete namespace openshell-oidc-labelfail42-rhbk" "${OC_LOG}" || {
	echo "FAIL: cleanup did not delete the run-owned namespace after the label failure" >&2
	cat "${OC_LOG}" >&2
	exit 1
}
[[ ! -f "${LABEL_STATE}/fixture.env" ]] || {
	echo "FAIL: fixture.env was written despite a setup failure" >&2
	exit 1
}
echo "ok: run-owned namespace cleaned after a setup failure"
grep -Fxq 'FIXTURE_NAMESPACE_DELETE_REQUESTED=1' "${LABEL_STATE}/state.env" || {
	echo "FAIL: cleanup did not persist the namespace delete request" >&2
	cat "${LABEL_STATE}/state.env" >&2
	exit 1
}

diagnostics_line="$(grep -n -m1 'get events --sort-by=.lastTimestamp' "${OC_LOG}" | cut -d: -f1)"
delete_line="$(grep -n -m1 'delete namespace openshell-oidc-labelfail42-rhbk' "${OC_LOG}" | cut -d: -f1)"
[[ -n "${diagnostics_line}" && "${diagnostics_line}" -lt "${delete_line}" ]] || {
	echo "FAIL: setup diagnostics were not collected before fixture cleanup" >&2
	cat "${OC_LOG}" >&2
	exit 1
}
echo "ok: setup diagnostics precede fixture cleanup"

echo ">> a rejected namespace delete is retried only for the recorded UID"
RETRY_STATE="${WORKDIR}/retry-state"
: > "${OC_LOG}"
set +e
run_fixture_setup "${RETRY_STATE}" \
	OPENSHELL_E2E_RUN_ID="retrydelete1" \
	OC_MOCK_LABEL_STATUS=42 \
	OC_MOCK_NAMESPACE_DELETE_STATUS=17
retry_first_status=$?
set -e
[[ "${retry_first_status}" != 0 ]] || {
	echo "FAIL: rejected namespace delete unexpectedly succeeded" >&2
	exit 1
}
grep -Fxq 'FIXTURE_NAMESPACE_DELETE_REQUESTED=1' "${RETRY_STATE}/state.env" || {
	echo "FAIL: rejected namespace delete did not preserve retry state" >&2
	exit 1
}
: > "${OC_LOG}"
set +e
env PATH="${MOCK_BIN}:${PATH}" \
	KUBECONFIG="${KUBECONFIG_FILE}" \
	PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_RUN_ID="retrydelete1" \
	OC_MOCK_NAMESPACE_EXISTS=0 \
	OC_MOCK_NAMESPACE_UID="fixture-namespace-uid" \
	OC_MOCK_NAMESPACE_DELETE_STATUS=0 \
	OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_ATTEMPTS=1 \
	OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_SLEEP=0 \
	"${FIXTURE}" cleanup --state-dir "${RETRY_STATE}" >"${WORKDIR}/retry-delete.log" 2>&1
retry_second_status=$?
set -e
[[ "${retry_second_status}" == 0 ]] || {
	echo "FAIL: cleanup did not retry a rejected delete for the same UID" >&2
	cat "${WORKDIR}/retry-delete.log" >&2
	exit 1
}
grep -Fxq 'delete namespace openshell-oidc-retrydelete1-rhbk' "${OC_LOG}" || {
	echo "FAIL: cleanup retry did not issue the namespace delete" >&2
	cat "${OC_LOG}" >&2
	exit 1
}
echo "ok: rejected namespace delete is safely retryable"

echo ">> an already-absent created namespace is a successful cleanup no-op"
: > "${OC_LOG}"
set +e
env PATH="${MOCK_BIN}:${PATH}" \
	KUBECONFIG="${KUBECONFIG_FILE}" \
	PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_RUN_ID="labelfail42" \
	OC_MOCK_NAMESPACE_EMPTY_UID=1 \
	OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_ATTEMPTS=1 \
	OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_SLEEP=0 \
	"${FIXTURE}" cleanup --state-dir "${LABEL_STATE}" >"${WORKDIR}/absent-namespace.log" 2>&1
absent_namespace_status=$?
set -e
[[ "${absent_namespace_status}" == 0 ]] || {
	echo "FAIL: cleanup rejected an already-absent created namespace" >&2
	cat "${WORKDIR}/absent-namespace.log" >&2
	exit 1
}
if grep -Eq '^delete (keycloakrealmimport|keycloak|route|deployment|service|pvc|secret|configmap) ' "${OC_LOG}"; then
	echo "FAIL: cleanup deleted resources after the namespace was already absent" >&2
	cat "${OC_LOG}" >&2
	exit 1
fi
echo "ok: absent namespace cleanup is a no-op"

echo ">> a cleanup retry never deletes a replacement namespace"
rm -f "${NAMESPACE_DELETE_MARKER}"
: > "${OC_LOG}"
set +e
env PATH="${MOCK_BIN}:${PATH}" \
	KUBECONFIG="${KUBECONFIG_FILE}" \
	PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_RUN_ID="labelfail42" \
	OC_MOCK_NAMESPACE_EXISTS=0 \
	OC_MOCK_NAMESPACE_UID="replacement-uid" \
	OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_ATTEMPTS=1 \
	OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_SLEEP=0 \
	"${FIXTURE}" cleanup --state-dir "${LABEL_STATE}" >"${WORKDIR}/replacement.log" 2>&1
replacement_status=$?
set -e
[[ "${replacement_status}" != 0 ]] || {
	echo "FAIL: cleanup accepted a replacement namespace" >&2
	cat "${WORKDIR}/replacement.log" >&2
	exit 1
}
if grep -Fq 'delete namespace openshell-oidc-labelfail42-rhbk' "${OC_LOG}"; then
	echo "FAIL: cleanup deleted a replacement namespace" >&2
	cat "${OC_LOG}" >&2
	exit 1
fi
for resource in \
	"delete keycloakrealmimport openshell-oidc-labelfail42-realm" \
	"delete keycloak openshell-oidc-labelfail42-keycloak" \
	"delete route openshell-oidc-labelfail42-keycloak" \
	"delete deployment openshell-oidc-labelfail42-postgres" \
	"delete service openshell-oidc-labelfail42-postgres" \
	"delete pvc openshell-oidc-labelfail42-postgres" \
	"delete secret openshell-oidc-labelfail42-keycloak-tls" \
	"delete secret openshell-oidc-labelfail42-postgres" \
	"delete configmap openshell-oidc-labelfail42-ca"; do
	if grep -Fq "${resource}" "${OC_LOG}"; then
		echo "FAIL: cleanup deleted replacement-namespace resource: ${resource}" >&2
		cat "${OC_LOG}" >&2
		exit 1
	fi
done
echo "ok: replacement namespace is protected by its recorded identity"

echo ">> a user-supplied RHBK namespace is never deleted and resources carry ownership labels"
: > "${OC_LOG}"
: > "${APPLY_MANIFESTS}"
USERNS_STATE="${WORKDIR}/userns-state"
set +e
run_fixture_setup "${USERNS_STATE}" \
	OPENSHELL_E2E_RUN_ID="usernsrun1" \
	OPENSHELL_E2E_RHBK_NAMESPACE="rhbk-operator-ns" \
	OC_MOCK_NAMESPACE_EXISTS=0 \
	OC_MOCK_ROLLOUT_STATUS=1
userns_status=$?
set -e
[[ "${userns_status}" != 0 ]] || {
	echo "FAIL: keycloak rollout failure unexpectedly succeeded" >&2
	exit 1
}
if grep -Fq "delete namespace rhbk-operator-ns" "${OC_LOG}"; then
	echo "FAIL: cleanup deleted the user-supplied RHBK namespace" >&2
	cat "${OC_LOG}" >&2
	exit 1
fi
if grep -Fq "label namespace rhbk-operator-ns" "${OC_LOG}"; then
	echo "FAIL: the user-supplied namespace was labelled for run ownership" >&2
	cat "${OC_LOG}" >&2
	exit 1
fi
for resource in \
	"delete deployment openshell-oidc-usernsrun1-postgres" \
	"delete service openshell-oidc-usernsrun1-postgres" \
	"delete pvc openshell-oidc-usernsrun1-postgres" \
	"delete secret openshell-oidc-usernsrun1-keycloak-tls" \
	"delete secret openshell-oidc-usernsrun1-postgres"; do
	grep -Fq "${resource}" "${OC_LOG}" || {
		echo "FAIL: cleanup did not delete an owned resource: ${resource}" >&2
		cat "${OC_LOG}" >&2
		exit 1
	}
done
grep -Fq 'openshell.nvidia.com/oidc-run: "usernsrun1"' "${APPLY_MANIFESTS}" || {
	echo "FAIL: applied manifests lack the run ownership label" >&2
	cat "${APPLY_MANIFESTS}" >&2
	exit 1
}
grep -Fq 'get keycloakrealmimport -l openshell.nvidia.com/oidc-run=usernsrun1 --ignore-not-found -o json' "${OC_LOG}" || {
	echo "FAIL: ownership lookup did not use a collection selector and JSON UID lookup" >&2
	cat "${OC_LOG}" >&2
	exit 1
}
[[ ! -f "${USERNS_STATE}/fixture.env" ]] || {
	echo "FAIL: fixture.env was written despite a rollout failure" >&2
	exit 1
}
[[ -z "$(find "${USERNS_STATE}" -name '*.key' -print -quit)" ]] || {
	echo "FAIL: fixture private keys lingered in the state directory" >&2
	find "${USERNS_STATE}" -name '*.key' >&2
	exit 1
}
echo "ok: fixture ownership and cleanup scope"

echo ">> cleanup skips a same-named resource owned by another run"
: > "${OC_LOG}"
set +e
env PATH="${MOCK_BIN}:${PATH}" \
	KUBECONFIG="${KUBECONFIG_FILE}" \
	PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_ATTEMPTS=1 \
	OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_SLEEP=0 \
	OPENSHELL_E2E_RUN_ID="usernsrun1" \
	OC_MOCK_FOREIGN_ROUTE=1 \
	"${FIXTURE}" cleanup --state-dir "${USERNS_STATE}" >"${WORKDIR}/foreign-owner.log" 2>&1
foreign_owner_status=$?
set -e
[[ "${foreign_owner_status}" == 0 ]] || {
	echo "FAIL: cleanup failed while skipping a foreign route" >&2
	cat "${WORKDIR}/foreign-owner.log" >&2
	exit 1
}
if grep -Fq 'delete route openshell-oidc-usernsrun1-keycloak' "${OC_LOG}"; then
	echo "FAIL: cleanup deleted a route owned by another run" >&2
	cat "${OC_LOG}" >&2
	exit 1
fi
echo "ok: foreign resources are not deleted"

echo ">> cleanup fails loudly when a resource survives its deletion"
SURVIVOR_STATE="${WORKDIR}/survivor-state"
mkdir -p "${SURVIVOR_STATE}"
cat > "${SURVIVOR_STATE}/fixture.env" <<'EOF'
export OPENSHELL_E2E_OIDC_ISSUER="https://kc.example.test/realms/openshell"
EOF
cat > "${SURVIVOR_STATE}/state.env" <<EOF
FIXTURE_NAMESPACE="openshell-oidc-survivor1-rhbk"
GATEWAY_NAMESPACE="openshell-oidc-survivor1"
GATEWAY_RELEASE="openshell-oidc-survivor1"
LABEL_KEY="openshell.nvidia.com/oidc-run"
LABEL_VALUE="survivor1"
KEYCLOAK_NAME="openshell-oidc-survivor1-keycloak"
POSTGRES_NAME="openshell-oidc-survivor1-postgres"
REALM_IMPORT_NAME="openshell-oidc-survivor1-realm"
TLS_SECRET_NAME="openshell-oidc-survivor1-keycloak-tls"
DB_SECRET_NAME="openshell-oidc-survivor1-postgres"
FIXTURE_CA_CONFIG_MAP_NAME="openshell-oidc-survivor1-ca"
KEYCLOAK_ROUTE_NAME="openshell-oidc-survivor1-keycloak"
FIXTURE_NAMESPACE_CREATED="0"
EOF
chmod 600 "${SURVIVOR_STATE}/fixture.env" "${SURVIVOR_STATE}/state.env"
# Temporarily replace the oc mock with one that reports the Keycloak CR as
# still present after deletion, delegating everything else to the real mock.
mv "${MOCK_BIN}/oc" "${WORKDIR}/oc-original"
cat > "${MOCK_BIN}/oc" <<OC
#!/usr/bin/env bash
args=("\$@")
joined=" \${args[*]} "
if [[ "\${joined}" == *" get keycloak "* && "\${joined}" == *"--ignore-not-found"* ]]; then
	if [[ "\${joined}" == *" -o json"* ]]; then
		printf '{"items":[{"metadata":{"name":"openshell-oidc-survivor1-keycloak","uid":"uid-survivor1-keycloak"}}]}\n'
	else
		printf 'keycloak.k8s.keycloak.org/openshell-oidc-survivor1-keycloak\n'
	fi
	exit 0
fi
exec "${WORKDIR}/oc-original" "\$@"
OC
chmod +x "${MOCK_BIN}/oc"
set +e
env PATH="${MOCK_BIN}:${PATH}" \
	KUBECONFIG="${KUBECONFIG_FILE}" \
	PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_RUN_ID="survivor1" \
	OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_ATTEMPTS=1 \
	OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_SLEEP=0 \
	"${FIXTURE}" cleanup --state-dir "${SURVIVOR_STATE}" >"${WORKDIR}/survivor.log" 2>&1
survivor_status=$?
set -e
mv -f "${WORKDIR}/oc-original" "${MOCK_BIN}/oc"
[[ "${survivor_status}" != 0 ]] || {
	echo "FAIL: a surviving resource passed cleanup" >&2
	exit 1
}
grep -Fq 'keycloak openshell-oidc-survivor1-keycloak was still present' "${WORKDIR}/survivor.log" || {
	echo "FAIL: the surviving resource was not named in the cleanup failure" >&2
	cat "${WORKDIR}/survivor.log" >&2
	exit 1
}
echo "ok: cleanup verification fails loudly"

echo ">> cleanup fails when the API cannot verify ownership"
: > "${OC_LOG}"
set +e
env PATH="${MOCK_BIN}:${PATH}" \
	KUBECONFIG="${KUBECONFIG_FILE}" \
	PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_RUN_ID="survivor1" \
	OC_MOCK_VERIFY_READ_STATUS=42 \
	"${FIXTURE}" cleanup --state-dir "${SURVIVOR_STATE}" >"${WORKDIR}/verify-error.log" 2>&1
verify_error_status=$?
set -e
[[ "${verify_error_status}" != 0 ]] || {
	echo "FAIL: cleanup treated an API read error as confirmed absence" >&2
	exit 1
}
grep -Fq 'could not verify ownership of keycloak' "${WORKDIR}/verify-error.log" || {
	echo "FAIL: cleanup did not report the ownership read error" >&2
	cat "${WORKDIR}/verify-error.log" >&2
	exit 1
}
echo "ok: cleanup distinguishes API errors from absence"

echo ">> diagnostics capture redacted logs for every component"
DIAG_STATE="${WORKDIR}/diag-state"
DIAG_RESULTS="${WORKDIR}/diag-results"
mkdir -p "${DIAG_STATE}" "${DIAG_RESULTS}"
cp "${SURVIVOR_STATE}/fixture.env" "${DIAG_STATE}/fixture.env"
cp "${SURVIVOR_STATE}/state.env" "${DIAG_STATE}/state.env"
printf '<testsuite name="oidc" tests="1"><testcase name="passes"/></testsuite>\n' > "${DIAG_RESULTS}/e2e-odh-oidc-shared-oidc.xml"
printf '{"issuer": "https://kc.example.test/realms/openshell"}\n' > "${DIAG_RESULTS}/oidc-diagrun1-identity.json"
printf 'pytest output with authorization: Bearer pytest-token-secret\n' > "${DIAG_RESULTS}/oidc-diagrun1-pytest.log"
sed -i.bak 's/survivor1/diagrun1/g; s/GATEWAY_NAMESPACE="openshell-oidc-diagrun1"/GATEWAY_NAMESPACE="openshell-gw-ns"/' "${DIAG_STATE}/state.env"
rm -f "${DIAG_STATE}/state.env.bak"
rm -f "${DIAG_STATE}/fixture.env"
PATH="${MOCK_BIN}:${PATH}" \
	KUBECONFIG="${KUBECONFIG_FILE}" \
	PYTHON_BIN="${PYTHON_TEST_BIN}" \
	OPENSHELL_E2E_RUN_ID="diagrun1" \
	OPENSHELL_E2E_RESULTS_DIR="${DIAG_RESULTS}" \
	"${FIXTURE}" diagnostics --state-dir "${DIAG_STATE}" >"${WORKDIR}/diagnostics.log" 2>&1
DIAG_DIR="${DIAG_RESULTS}/oidc-diagrun1-diagnostics"
for artifact in \
	"keycloak/logs.txt" \
	"postgres/logs.txt" \
	"gateway/pod-gw-pod-1.log" \
	"supervisor/pod-sup-pod-1.log" \
	"supervisor/pod-shared-sup-pod-1.log" \
	"sandbox/pod-sbx-pod-1.log" \
	"test-run/e2e-odh-oidc-shared-oidc.xml" \
	"test-run/oidc-diagrun1-pytest.log"; do
	[[ -f "${DIAG_DIR}/${artifact}" ]] || {
		echo "FAIL: diagnostics are missing ${artifact}" >&2
		find "${DIAG_DIR}" -type f >&2 || true
		exit 1
	}
done
for artifact in "gateway/pod-gw-pod-1.log" "supervisor/pod-sup-pod-1.log" "supervisor/pod-shared-sup-pod-1.log" "sandbox/pod-sbx-pod-1.log"; do
	if grep -Fq 'diagnostic-token-secret' "${DIAG_DIR}/${artifact}"; then
		echo "FAIL: diagnostics retained an unredacted token in ${artifact}" >&2
		exit 1
	fi
	grep -Fq 'Bearer [REDACTED]' "${DIAG_DIR}/${artifact}" || {
		echo "FAIL: diagnostics did not preserve the redacted bearer marker in ${artifact}" >&2
		exit 1
	}
done
if grep -Fq 'pytest-token-secret' "${DIAG_DIR}/test-run/oidc-diagrun1-pytest.log"; then
	echo "FAIL: diagnostics retained an unredacted pytest token" >&2
	exit 1
fi
echo "ok: per-component diagnostics"

grep -Fq 'scopes_claim: scope' "${FIXTURE_SETUP}" || {
	echo "FAIL: fixture values overlay must configure the scopes claim" >&2
	exit 1
}
echo "ok: fixture values overlay configures scope claims"

# ── Entrypoint OIDC lane lifecycle with mocked fixture/deploy/session ───────

LIFE_DIR="${WORKDIR}/lifecycle"
MOCK_LIFE_BIN="${LIFE_DIR}/bin"
LIFE_LOG="${LIFE_DIR}/flow.log"
DEPLOY_LOG="${LIFE_DIR}/deploy.log"
SESSION_LOG="${LIFE_DIR}/session.log"
VALIDATOR_LOG="${LIFE_DIR}/validator.log"
MERGE_ARGS="${LIFE_DIR}/merge-args"
LIFE_KUBECONFIG="${LIFE_DIR}/kubeconfig"
MOCK_FIXTURE="${LIFE_DIR}/mock-fixture.sh"
MOCK_DEPLOY="${LIFE_DIR}/mock-deploy.sh"
MOCK_SESSION="${LIFE_DIR}/mock-session.sh"
MOCK_VALIDATOR="${LIFE_DIR}/mock-validator.py"
MOCK_MERGER="${LIFE_DIR}/mock-merger.py"
mkdir -p "${MOCK_LIFE_BIN}" "${LIFE_DIR}/results" "${LIFE_DIR}/tmp"
: > "${LIFE_LOG}"
: > "${DEPLOY_LOG}"
: > "${SESSION_LOG}"
: > "${VALIDATOR_LOG}"
printf 'apiVersion: v1\nkind: Config\n' > "${LIFE_KUBECONFIG}"

cat > "${MOCK_FIXTURE}" <<SH
#!/usr/bin/env bash
set -euo pipefail
action="\$1"
shift
[[ "\$1" == "--state-dir" ]] || { echo "missing --state-dir" >&2; exit 2; }
state="\$2"
case "\${action}" in
	setup)
		mkdir -p "\${state}"
		printf 'certificate\n' > "\${state}/ca.crt"
		printf 'gatewayConfig: openshell\n' > "\${state}/values.yaml"
		cat > "\${state}/fixture.env" <<EOF
export OPENSHELL_E2E_OIDC_ISSUER="https://kc-oidc.example.test/realms/openshell"
export OPENSHELL_KEYCLOAK_URL="https://kc-oidc.example.test"
export OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT="https://gw-oidc.example.test"
export ROUTE_HOST="gw-oidc.example.test"
export OPENSHELL_E2E_RHBK_NAMESPACE="rhbk-operator-ns"
export OPENSHELL_E2E_OIDC_CA_CERT_FILE="\${state}/ca.crt"
export OPENSHELL_E2E_OIDC_CA_CONFIG_MAP_NAME="openshell-oidc-lane-ca"
export OPENSHELL_E2E_OIDC_VALUES_FILE="\${state}/values.yaml"
export OIDC_IDENTITY_ADMIN_ROLE="openshell-admin"
export OIDC_IDENTITY_USER_ROLE="openshell-user"
export OIDC_IDENTITY_SCOPE="openshell:all"
EOF
		chmod 600 "\${state}/fixture.env"
		printf 'fixture:setup\n' >> "${LIFE_LOG}"
		cat > "\${state}/state.env" <<EOF
FIXTURE_NAMESPACE="rhbk-operator-ns"
GATEWAY_NAMESPACE="openshell-oidc-lane"
GATEWAY_RELEASE="openshell-oidc-lane"
LABEL_KEY="openshell.nvidia.com/oidc-run"
LABEL_VALUE="lifecycle"
FIXTURE_NAMESPACE_CREATED="0"
EOF
		chmod 600 "\${state}/state.env"
		exit 0
		;;
	cleanup)
		printf 'fixture:cleanup\n' >> "${LIFE_LOG}"
		exit "\${MOCK_FIXTURE_CLEANUP_STATUS:-0}"
		;;
	diagnostics)
		printf 'fixture:diagnostics\n' >> "${LIFE_LOG}"
		mkdir -p "${LIFE_DIR}/results/oidc-diagnostics"
		exit 0
		;;
esac
exit 2
SH
cat > "${MOCK_DEPLOY}" <<SH
#!/usr/bin/env bash
case "\$1" in
	deploy)
		printf 'deploy:deploy\n' >> "${LIFE_LOG}"
		{
			printf 'NAMESPACE=%s\n' "\${NAMESPACE:-}"
			printf 'RELEASE=%s\n' "\${RELEASE:-}"
			printf 'OIDC_VALUES=%s\n' "\${OPENSHELL_E2E_OIDC_VALUES_FILE:-}"
			printf 'OIDC_CA=%s\n' "\${OPENSHELL_E2E_OIDC_CA_CERT_FILE:-}"
			printf 'OIDC_CONFIGMAP=%s\n' "\${OPENSHELL_E2E_OIDC_CA_CONFIG_MAP_NAME:-}"
			printf 'ROUTE_HOST=%s\n' "\${ROUTE_HOST:-}"
		} >> "${DEPLOY_LOG}"
		if [[ -n "\${OPENSHELL_E2E_DEPLOY_STATE_DIR:-}" ]]; then
			: > "\${OPENSHELL_E2E_DEPLOY_STATE_DIR}/namespace"
			: > "\${OPENSHELL_E2E_DEPLOY_STATE_DIR}/gateway"
		fi
		exit "\${MOCK_DEPLOY_STATUS:-0}"
		;;
	teardown)
		printf 'deploy:teardown\n' >> "${LIFE_LOG}"
		exit 0
		;;
esac
exit 0
SH
cat > "${MOCK_SESSION}" <<SH
#!/usr/bin/env bash
printf 'session:establish\n' >> "${LIFE_LOG}"
printf 'GATEWAY_NAME=%s\nISSUER=%s\n' "\${GATEWAY_NAME:-}" "\${OPENSHELL_E2E_OIDC_ISSUER:-}" >> "${SESSION_LOG}"
exit "\${MOCK_SESSION_STATUS:-0}"
SH
cat > "${MOCK_VALIDATOR}" <<PY
import os

with open(os.environ["LIFE_LOG"], "a", encoding="utf-8") as flow:
    flow.write("validator:preflight\n")
with open(os.environ["VALIDATOR_LOG"], "a", encoding="utf-8") as stream:
    for name in (
        "OIDC_IDENTITY_ISSUER",
        "OIDC_IDENTITY_CA_FILE",
        "OIDC_IDENTITY_SUMMARY",
        "OIDC_IDENTITY_ADMIN_PASSWORD",
		"OIDC_IDENTITY_USER_PASSWORD",
		"OIDC_IDENTITY_USER_B_PASSWORD",
		"OIDC_IDENTITY_CI_CLIENT_SECRET",
    ):
        value = os.environ.get(name, "")
        if name.endswith("PASSWORD") or name.endswith("CLIENT_SECRET"):
            stream.write(f"{name}_PRESENT={bool(value)}\n")
        else:
            stream.write(f"{name}={value}\n")
        if name.endswith("PASSWORD"):
            stream.write(f"{name}_DEFAULT={value in {'admin', 'password', 'changeme'}}\n")
raise SystemExit(int(os.environ.get("MOCK_VALIDATOR_STATUS", "0")))
PY
cat > "${MOCK_MERGER}" <<PY
import os
import sys
from pathlib import Path

Path(os.environ["MERGE_ARGS"]).write_text("\n".join(sys.argv[2:]) + "\n")
PY
chmod +x "${MOCK_FIXTURE}" "${MOCK_DEPLOY}" "${MOCK_SESSION}"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${MOCK_LIFE_BIN}/oc"
chmod +x "${MOCK_LIFE_BIN}/oc"

run_entrypoint_oidc() {
	local results_dir="$1" log_file="$2"
	shift 2
	env \
		-u OPENSHELL_E2E_OIDC_ADMIN_PASSWORD \
		-u OPENSHELL_E2E_OIDC_USER_PASSWORD \
		-u OPENSHELL_E2E_OIDC_USER_B_PASSWORD \
		-u OPENSHELL_E2E_OIDC_CI_CLIENT_SECRET \
		"$@" \
		KUBECONFIG="${LIFE_KUBECONFIG}" \
		TMPDIR="${LIFE_DIR}/tmp" \
		OPENSHELL_E2E_RESULTS_DIR="${results_dir}" \
		OPENSHELL_E2E_DEPLOY_SCRIPT="${MOCK_DEPLOY}" \
		OPENSHELL_E2E_OIDC_FIXTURE="${MOCK_FIXTURE}" \
		OPENSHELL_E2E_OIDC_SESSION_SCRIPT="${MOCK_SESSION}" \
		OPENSHELL_E2E_OIDC_IDENTITY_VALIDATOR="${MOCK_VALIDATOR}" \
		OPENSHELL_E2E_REPORT_MERGER="${MOCK_MERGER}" \
		OPENSHELL_E2E_PYTHON="${FAKE_PYTHON}" \
		OPENSHELL_BIN="${MOCK_LIFE_BIN}/oc" \
		PYTHON_BIN="${PYTHON_TEST_BIN}" \
		VALIDATOR_LOG="${VALIDATOR_LOG}" \
		MERGE_ARGS="${MERGE_ARGS}" \
		LIFE_LOG="${LIFE_LOG}" \
		DEPLOY_LOG="${DEPLOY_LOG}" \
		GATEWAY_IMAGE="quay.io/opendatahub/odh-openshell-gateway@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
		SUPERVISOR_IMAGE="quay.io/opendatahub/odh-openshell-supervisor@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
		SANDBOX_IMAGE="quay.io/opendatahub/odh-openshell-sandbox@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
		PATH="${MOCK_LIFE_BIN}:${PATH}" \
		"${ENTRYPOINT}" oidc > "${log_file}" 2>&1
}

echo ">> no-deploy mode cannot run the OIDC lane"
NO_DEPLOY_LOG="${LIFE_DIR}/no-deploy.log"
if run_entrypoint_oidc "${LIFE_DIR}/results-no-deploy" "${NO_DEPLOY_LOG}" OPENSHELL_E2E_DEPLOY_GATEWAY=0; then
	echo "FAIL: no-deploy OIDC lane unexpectedly succeeded" >&2
	exit 1
fi
grep -q 'cannot be used with the OIDC lane' "${NO_DEPLOY_LOG}" || {
	echo "FAIL: no-deploy rejection did not name the OIDC constraint" >&2
	cat "${NO_DEPLOY_LOG}" >&2
	exit 1
}
echo "ok: OIDC lane requires deployment"

echo ">> the happy path runs fixture, deploy, preflight, session, runner, teardown, and cleanup"
HAPPY_RESULTS="${LIFE_DIR}/results-happy"
HAPPY_LOG="${LIFE_DIR}/happy.log"
mkdir -p "${HAPPY_RESULTS}"
run_entrypoint_oidc "${HAPPY_RESULTS}" "${HAPPY_LOG}"
expected_flow="fixture:setup
deploy:deploy
validator:preflight
session:establish
deploy:teardown
fixture:cleanup"
[[ "$(grep -E '^(fixture|deploy|session|validator):' "${LIFE_LOG}")" == "${expected_flow}" ]] || {
	echo "FAIL: OIDC lane flow order mismatch" >&2
	grep -E '^(fixture|deploy|session|validator):' "${LIFE_LOG}" >&2
	exit 1
}
expected_merge="${HAPPY_RESULTS}/e2e-odh-oidc-shared-oidc.xml"
[[ "$(cat "${MERGE_ARGS}")" == "${expected_merge}" ]] || {
	echo "FAIL: merger did not receive the OIDC phase report path" >&2
	cat "${MERGE_ARGS}" >&2
	exit 1
}
grep -Eq '^NAMESPACE=openshell-oidc-[a-z0-9-]+$' "${DEPLOY_LOG}" || {
	echo "FAIL: the OIDC lane did not use a run-scoped namespace" >&2
	cat "${DEPLOY_LOG}" >&2
	exit 1
}
grep -Eq '^RELEASE=openshell-oidc-[a-z0-9-]+$' "${DEPLOY_LOG}" || {
	echo "FAIL: the OIDC lane did not use a run-scoped release" >&2
	cat "${DEPLOY_LOG}" >&2
	exit 1
}
grep -q '^OIDC_VALUES=.*/values.yaml$' "${DEPLOY_LOG}" || {
	echo "FAIL: deploy did not receive the OIDC values overlay from the fixture" >&2
	cat "${DEPLOY_LOG}" >&2
	exit 1
}
grep -q '^OIDC_CA=.*/ca.crt$' "${DEPLOY_LOG}" || {
	echo "FAIL: deploy did not receive the OIDC CA bundle from the fixture" >&2
	cat "${DEPLOY_LOG}" >&2
	exit 1
}
grep -q '^OIDC_CONFIGMAP=openshell-oidc-lane-ca$' "${DEPLOY_LOG}" || {
	echo "FAIL: deploy did not receive the OIDC CA ConfigMap name" >&2
	cat "${DEPLOY_LOG}" >&2
	exit 1
}
grep -q '^ROUTE_HOST=gw-oidc.example.test$' "${DEPLOY_LOG}" || {
	echo "FAIL: deploy did not receive the fixture-derived Route host" >&2
	cat "${DEPLOY_LOG}" >&2
	exit 1
}
grep -q '^OIDC_IDENTITY_ISSUER=https://kc-oidc.example.test/realms/openshell$' "${VALIDATOR_LOG}" || {
	echo "FAIL: identity preflight did not receive the fixture issuer" >&2
	cat "${VALIDATOR_LOG}" >&2
	exit 1
}
grep -Fxq 'OIDC_IDENTITY_ADMIN_PASSWORD_PRESENT=True' "${VALIDATOR_LOG}" || {
	echo "FAIL: identity preflight did not receive an admin password" >&2
	cat "${VALIDATOR_LOG}" >&2
	exit 1
}
if grep -Fxq 'OIDC_IDENTITY_ADMIN_PASSWORD_DEFAULT=True' "${VALIDATOR_LOG}"; then
	echo "FAIL: identity preflight received the published default admin password" >&2
	cat "${VALIDATOR_LOG}" >&2
	exit 1
fi
grep -Fxq 'OIDC_IDENTITY_CI_CLIENT_SECRET_PRESENT=True' "${VALIDATOR_LOG}" || {
	echo "FAIL: identity preflight did not receive the per-run CI client secret" >&2
	cat "${VALIDATOR_LOG}" >&2
	exit 1
}
grep -Eq '^OIDC_IDENTITY_SUMMARY=.*/oidc-[a-z0-9-]+-identity\.json$' "${VALIDATOR_LOG}" || {
	echo "FAIL: identity preflight summary was not results-scoped" >&2
	cat "${VALIDATOR_LOG}" >&2
	exit 1
}
[[ -f "${HAPPY_RESULTS}/e2e-odh-oidc-shared-oidc.xml" ]] || {
	echo "FAIL: the OIDC runner did not write its phase report" >&2
	exit 1
}
grep -q 'OIDC lane: issuer https://kc-oidc.example.test/realms/openshell' "${HAPPY_LOG}" || {
	echo "FAIL: the entrypoint did not log the fixture-derived issuer" >&2
	cat "${HAPPY_LOG}" >&2
	exit 1
}
echo "ok: OIDC lane happy path"

echo ">> two invocations use isolated run-scoped namespaces and releases"
SECOND_RESULTS="${LIFE_DIR}/results-second"
SECOND_LOG="${LIFE_DIR}/second.log"
mkdir -p "${SECOND_RESULTS}"
run_entrypoint_oidc "${SECOND_RESULTS}" "${SECOND_LOG}"
first_namespace="$(grep '^NAMESPACE=' "${DEPLOY_LOG}" | head -1)"
second_namespace="$(grep '^NAMESPACE=' "${DEPLOY_LOG}" | tail -1)"
first_release="$(grep '^RELEASE=' "${DEPLOY_LOG}" | head -1)"
second_release="$(grep '^RELEASE=' "${DEPLOY_LOG}" | tail -1)"
[[ "${first_namespace}" != "${second_namespace}" ]] || {
	echo "FAIL: two OIDC invocations shared a namespace: ${first_namespace}" >&2
	exit 1
}
[[ "${first_release}" != "${second_release}" ]] || {
	echo "FAIL: two OIDC invocations shared a release: ${first_release}" >&2
	exit 1
}
echo "ok: run-scoped isolation between invocations"

echo ">> a deployment failure still cleans up the fixture"
: > "${LIFE_LOG}"
DEPLOY_FAIL_RESULTS="${LIFE_DIR}/results-deploy-fail"
DEPLOY_FAIL_LOG="${LIFE_DIR}/deploy-fail.log"
mkdir -p "${DEPLOY_FAIL_RESULTS}"
printf '<testsuites/>\n' > "${DEPLOY_FAIL_RESULTS}/e2e-odh-oidc-shared-oidc.xml"
set +e
run_entrypoint_oidc "${DEPLOY_FAIL_RESULTS}" "${DEPLOY_FAIL_LOG}" MOCK_DEPLOY_STATUS=1
deploy_fail_status=$?
set -e
[[ "${deploy_fail_status}" != 0 ]] || {
	echo "FAIL: deployment failure unexpectedly succeeded" >&2
	exit 1
}
grep -Fxq 'fixture:setup' "${LIFE_LOG}" || {
	echo "FAIL: fixture setup was not recorded" >&2
	cat "${LIFE_LOG}" >&2
	exit 1
}
grep -Fxq 'fixture:diagnostics' "${LIFE_LOG}" || {
	echo "FAIL: fixture diagnostics were not collected after the deployment failure" >&2
	cat "${LIFE_LOG}" >&2
	exit 1
}
diagnostics_line="$(grep -n -m1 -F 'fixture:diagnostics' "${LIFE_LOG}" | cut -d: -f1)"
teardown_line="$(grep -n -m1 -F 'deploy:teardown' "${LIFE_LOG}" | cut -d: -f1)"
[[ "${diagnostics_line}" -lt "${teardown_line}" ]] || {
	echo "FAIL: diagnostics were collected after gateway teardown" >&2
	cat "${LIFE_LOG}" >&2
	exit 1
}
grep -Fxq 'fixture:cleanup' "${LIFE_LOG}" || {
	echo "FAIL: fixture cleanup did not run after the deployment failure" >&2
	cat "${LIFE_LOG}" >&2
	exit 1
}
[[ ! -e "${DEPLOY_FAIL_RESULTS}/e2e-odh-oidc-shared-oidc.xml" ]] || {
	echo "FAIL: a stale OIDC report survived a deployment failure" >&2
	exit 1
}
grep -q 'deployment/preflight failed for oidc/shared' "${DEPLOY_FAIL_LOG}" || {
	echo "FAIL: deployment failure was not reported" >&2
	cat "${DEPLOY_FAIL_LOG}" >&2
	exit 1
}
echo "ok: cleanup after deployment failure"

echo ">> a fixture-cleanup failure does not hide the primary runner failure"
: > "${LIFE_LOG}"
CLEANUP_FAIL_RESULTS="${LIFE_DIR}/results-cleanup-fail"
CLEANUP_FAIL_LOG="${LIFE_DIR}/cleanup-fail.log"
mkdir -p "${CLEANUP_FAIL_RESULTS}"
set +e
FAKE_PYTEST_STATUS=4 MOCK_FIXTURE_CLEANUP_STATUS=7 \
	run_entrypoint_oidc "${CLEANUP_FAIL_RESULTS}" "${CLEANUP_FAIL_LOG}"
cleanup_fail_status=$?
set -e
[[ "${cleanup_fail_status}" == 4 ]] || {
	echo "FAIL: cleanup failure masked the primary status (got ${cleanup_fail_status}, expected 4)" >&2
	cat "${CLEANUP_FAIL_LOG}" >&2
	exit 1
}
grep -Fxq 'fixture:cleanup' "${LIFE_LOG}" || {
	echo "FAIL: fixture cleanup was not attempted" >&2
	cat "${LIFE_LOG}" >&2
	exit 1
}
grep -q 'OIDC fixture cleanup failed' "${CLEANUP_FAIL_LOG}" || {
	echo "FAIL: the cleanup failure was not reported" >&2
	cat "${CLEANUP_FAIL_LOG}" >&2
	exit 1
}
preserved_state="$(sed -n 's/.*Preserving OIDC fixture state for retry: //p' "${CLEANUP_FAIL_LOG}" | tail -1)"
[[ -n "${preserved_state}" && -f "${preserved_state}/state.env" ]] || {
	echo "FAIL: cleanup failure removed the state needed for retry" >&2
	cat "${CLEANUP_FAIL_LOG}" >&2
	exit 1
}
echo "ok: primary failure preserved"

echo ">> failure retention keeps the fixture for diagnosis"
: > "${LIFE_LOG}"
RETAIN_RESULTS="${LIFE_DIR}/results-retain"
RETAIN_LOG="${LIFE_DIR}/retain.log"
mkdir -p "${RETAIN_RESULTS}"
set +e
FAKE_PYTEST_STATUS=4 OPENSHELL_E2E_RETAIN_ON_FAILURE=1 \
	run_entrypoint_oidc "${RETAIN_RESULTS}" "${RETAIN_LOG}"
retain_status=$?
set -e
[[ "${retain_status}" == 4 ]] || {
	echo "FAIL: retained run did not keep its primary status (got ${retain_status})" >&2
	exit 1
}
grep -Fxq 'fixture:diagnostics' "${LIFE_LOG}" || {
	echo "FAIL: diagnostics were not collected for the retained failure" >&2
	cat "${LIFE_LOG}" >&2
	exit 1
}
if grep -Fxq 'fixture:cleanup' "${LIFE_LOG}"; then
	echo "FAIL: fixture cleanup ran despite retention" >&2
	cat "${LIFE_LOG}" >&2
	exit 1
fi
grep -q 'Retaining OIDC fixture for diagnosis' "${RETAIN_LOG}" || {
	echo "FAIL: retention was not reported" >&2
	cat "${RETAIN_LOG}" >&2
	exit 1
}
echo "ok: failure retention"

echo "ODH OIDC lane tests passed."
