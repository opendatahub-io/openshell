#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Run the OpenShift OIDC suite with an isolated Keycloak fixture. A caller may
# point at an existing RHBK operator namespace, or the runner bootstraps a
# per-run installation and removes its namespace during cleanup. All resources
# are labelled with the per-run identifier.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/openshell-deploy-from-quay.sh"
RESULTS_DIR="${OPENSHELL_E2E_RESULTS_DIR:-${ROOT}/results}"
RETAIN_ON_FAILURE="${OPENSHELL_E2E_RETAIN_ON_FAILURE:-0}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

fail() { echo "ERROR: $*" >&2; exit 1; }

for tool in oc helm openssl "${PYTHON_BIN}" uv; do
	command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required"
done

if [[ -z "${KUBECONFIG:-}" ]]; then
	KUBECONFIG="${ROOT}/.kube/config"
	export KUBECONFIG
fi
[[ -f "${KUBECONFIG}" ]] || fail "kubeconfig not found at ${KUBECONFIG}"
oc whoami >/dev/null || fail "unable to authenticate to OpenShift"

raw_run_id="${OPENSHELL_E2E_RUN_ID:-$(date +%s)-$(openssl rand -hex 4)}"
RUN_ID="$(printf '%s' "${raw_run_id}" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
RUN_ID="${RUN_ID#-}"; RUN_ID="${RUN_ID%-}"
# RHBK derives a Service named "${RESOURCE_PREFIX}-keycloak-discovery".
# Kubernetes resource names are limited to 63 characters, leaving 29 for the
# per-run suffix after the fixed prefix and derived suffix.
[[ -n "${RUN_ID}" && "${#RUN_ID}" -le 29 ]] || fail "OPENSHELL_E2E_RUN_ID must be 1-29 DNS-safe characters"

RESOURCE_PREFIX="openshell-oidc-${RUN_ID}"
LABEL_KEY="openshell.nvidia.com/oidc-run"
LABEL_VALUE="${RUN_ID}"
KEYCLOAK_NAME="${RESOURCE_PREFIX}-keycloak"
POSTGRES_NAME="${RESOURCE_PREFIX}-postgres"
REALM_IMPORT_NAME="${RESOURCE_PREFIX}-realm"
TLS_SECRET_NAME="${RESOURCE_PREFIX}-keycloak-tls"
DB_SECRET_NAME="${RESOURCE_PREFIX}-postgres"
FIXTURE_SECRET_NAME="${RESOURCE_PREFIX}-credentials"
CA_CONFIG_MAP_NAME="${RESOURCE_PREFIX}-ca"
FIXTURE_NAMESPACE="${OPENSHELL_E2E_RHBK_NAMESPACE:-${RESOURCE_PREFIX}-rhbk}"
RHBK_SUBSCRIPTION_NAME="${OPENSHELL_E2E_RHBK_SUBSCRIPTION_NAME:-rhbk-operator}"
RHBK_OPERATOR_CHANNEL="${OPENSHELL_E2E_RHBK_CHANNEL:-stable-v26.6}"
RHBK_OPERATOR_SOURCE="${OPENSHELL_E2E_RHBK_SOURCE:-redhat-operators}"
RHBK_OPERATOR_SOURCE_NAMESPACE="${OPENSHELL_E2E_RHBK_SOURCE_NAMESPACE:-openshift-marketplace}"
POSTGRES_IMAGE="${OPENSHELL_E2E_POSTGRES_IMAGE:-registry.redhat.io/rhel9/postgresql-16@sha256:565a44d683b390a10a3fe8d2cbbfd899db017821e0012e99aa6c5b37ea4438b5}"
KEYCLOAK_ROUTE_NAME="${RESOURCE_PREFIX}-keycloak"
OPENSHIFT_APPS_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
KEYCLOAK_ROUTE_HOST="${RESOURCE_PREFIX}-keycloak.${OPENSHIFT_APPS_DOMAIN}"
OPENSHIFT_NAMESPACE="${NAMESPACE:-${RESOURCE_PREFIX}}"
OPENSHIFT_RELEASE="${RELEASE:-${RESOURCE_PREFIX}}"
GATEWAY_NAME="${GATEWAY_NAME:-${RESOURCE_PREFIX}}"
OPENSHIFT_ROUTE_HOST="${ROUTE_HOST:-${RESOURCE_PREFIX}.${OPENSHIFT_APPS_DOMAIN}}"
OIDC_ISSUER="https://${KEYCLOAK_ROUTE_HOST}/realms/openshell"
# Keep the expiry assertion fast while ensuring it exercises a real JWT expiry
# rather than an invalid-token shortcut. This setting applies only to the
# per-run OCP realm; the shared local Keycloak fixture keeps its normal value.
OIDC_ACCESS_TOKEN_LIFESPAN="${OPENSHELL_E2E_OIDC_ACCESS_TOKEN_LIFESPAN:-10}"
[[ "${OIDC_ACCESS_TOKEN_LIFESPAN}" =~ ^[1-9][0-9]*$ && "${OIDC_ACCESS_TOKEN_LIFESPAN}" -le 20 ]] \
	|| fail "OPENSHELL_E2E_OIDC_ACCESS_TOKEN_LIFESPAN must be an integer from 1 to 20"
OIDC_CLIENT_SESSION_MAX_LIFESPAN="${OPENSHELL_E2E_OIDC_CLIENT_SESSION_MAX_LIFESPAN:-15}"
[[ "${OIDC_CLIENT_SESSION_MAX_LIFESPAN}" =~ ^[1-9][0-9]*$ \
	&& "${OIDC_CLIENT_SESSION_MAX_LIFESPAN}" -gt "${OIDC_ACCESS_TOKEN_LIFESPAN}" \
	&& "${OIDC_CLIENT_SESSION_MAX_LIFESPAN}" -le 30 ]] \
	|| fail "OPENSHELL_E2E_OIDC_CLIENT_SESSION_MAX_LIFESPAN must be an integer greater than the access token lifespan and no greater than 30"

mkdir -p "${RESULTS_DIR}"
WORKDIR="$(mktemp -d)"; chmod 700 "${WORKDIR}"
GATEWAY_MTLS_DIR="${WORKDIR}/gateway-mtls"
CA_CERT_FILE="${WORKDIR}/keycloak-ca.crt"
REALM_FILE="${WORKDIR}/realm.json"
PYTEST_LOG="${RESULTS_DIR}/oidc-${RUN_ID}-pytest.log"
PYTEST_RAW_LOG="${WORKDIR}/pytest.raw.log"
PYTEST_JUNIT_RAW="${WORKDIR}/e2e-odh-oidc.xml"
PYTEST_JUNIT="${RESULTS_DIR}/e2e-odh-oidc.xml"
IDENTITY_SUMMARY="${RESULTS_DIR}/oidc-${RUN_ID}-identity.json"
cleanup_enabled=0
openshell_deployed=0
fixture_namespace_created=0
db_password=""
admin_password=""
user_password=""
user_b_password=""
client_secret=""

redact_file() {
	local source="$1" destination="$2"
	[[ -f "${source}" ]] || return 0
	OIDC_REDACT_DB_PASSWORD="${db_password}" \
	OIDC_REDACT_ADMIN_PASSWORD="${admin_password}" \
	OIDC_REDACT_USER_PASSWORD="${user_password}" \
	OIDC_REDACT_USER_B_PASSWORD="${user_b_password}" \
	OIDC_REDACT_CLIENT_SECRET="${client_secret}" \
	"${PYTHON_BIN}" "${SCRIPT_DIR}/redact-oidc-artifact.py" "${source}" "${destination}"
}

capture_diagnostic() {
	local destination="$1" raw
	shift
	raw="${WORKDIR}/$(basename "${destination}").raw"
	"$@" >"${raw}" 2>&1 || true
	redact_file "${raw}" "${destination}"
	rm -f "${raw}"
}

redact_pytest_artifacts() {
	redact_file "${PYTEST_RAW_LOG}" "${PYTEST_LOG}"
	redact_file "${PYTEST_JUNIT_RAW}" "${PYTEST_JUNIT}"
	rm -f "${PYTEST_RAW_LOG}" "${PYTEST_JUNIT_RAW}"
}

collect_diagnostics() {
	local diagnostics_dir="${RESULTS_DIR}/oidc-${RUN_ID}-diagnostics"
	mkdir -p "${diagnostics_dir}"
	capture_diagnostic "${diagnostics_dir}/resources.txt" oc -n "${FIXTURE_NAMESPACE}" get keycloak,keycloakrealmimport,deploy,statefulset,pod,service,pvc,route \
		-l "${LABEL_KEY}=${LABEL_VALUE}" -o wide
	capture_diagnostic "${diagnostics_dir}/events.txt" oc -n "${FIXTURE_NAMESPACE}" get events --sort-by=.lastTimestamp
	capture_diagnostic "${diagnostics_dir}/keycloak.log" oc -n "${FIXTURE_NAMESPACE}" logs "statefulset/${KEYCLOAK_NAME}" --all-containers --tail=300
	capture_diagnostic "${diagnostics_dir}/openshell-resources.txt" oc -n "${OPENSHIFT_NAMESPACE}" get pods,route -o wide
	capture_diagnostic "${diagnostics_dir}/openshell-events.txt" oc -n "${OPENSHIFT_NAMESPACE}" get events --sort-by=.lastTimestamp
	capture_diagnostic "${diagnostics_dir}/openshell-manifests.yaml" oc -n "${OPENSHIFT_NAMESPACE}" get deploy,statefulset,service,route -o yaml
	[[ ! -f "${PYTEST_LOG}" ]] || cp "${PYTEST_LOG}" "${diagnostics_dir}/pytest.log"
	[[ ! -f "${IDENTITY_SUMMARY}" ]] || cp "${IDENTITY_SUMMARY}" "${diagnostics_dir}/identity.json"
	while IFS= read -r pod; do
		pod="${pod#pod/}"
		capture_diagnostic "${diagnostics_dir}/openshell-${pod}.log" oc -n "${OPENSHIFT_NAMESPACE}" logs "${pod}" --all-containers --tail=300
	done < <(oc -n "${OPENSHIFT_NAMESPACE}" get pods -o name 2>/dev/null || true)
}

cleanup() {
	local status=$? cleanup_status=0
	trap - EXIT INT TERM
	if [[ "${status}" != 0 ]]; then
		redact_pytest_artifacts
		collect_diagnostics
	fi
	if [[ "${cleanup_enabled}" == 1 && ! ( "${status}" != 0 && "${RETAIN_ON_FAILURE}" == 1 ) ]]; then
		if [[ "${openshell_deployed}" == 1 ]]; then
			NAMESPACE="${OPENSHIFT_NAMESPACE}" RELEASE="${OPENSHIFT_RELEASE}" GATEWAY_NAME="${GATEWAY_NAME}" \
				"${DEPLOY_SCRIPT}" teardown --yes || cleanup_status=$?
		fi
		oc -n "${FIXTURE_NAMESPACE}" delete keycloakrealmimport "${REALM_IMPORT_NAME}" --ignore-not-found --wait=false || cleanup_status=$?
		oc -n "${FIXTURE_NAMESPACE}" delete keycloak "${KEYCLOAK_NAME}" --ignore-not-found --wait=false || cleanup_status=$?
		oc -n "${FIXTURE_NAMESPACE}" delete route "${KEYCLOAK_ROUTE_NAME}" --ignore-not-found --wait=false || cleanup_status=$?
		oc -n "${FIXTURE_NAMESPACE}" delete deployment "${POSTGRES_NAME}" --ignore-not-found --wait=false || cleanup_status=$?
		oc -n "${FIXTURE_NAMESPACE}" delete service "${POSTGRES_NAME}" --ignore-not-found --wait=false || cleanup_status=$?
		oc -n "${FIXTURE_NAMESPACE}" delete pvc "${POSTGRES_NAME}" --ignore-not-found --wait=false || cleanup_status=$?
		oc -n "${FIXTURE_NAMESPACE}" delete secret "${TLS_SECRET_NAME}" "${DB_SECRET_NAME}" "${FIXTURE_SECRET_NAME}" --ignore-not-found --wait=false || cleanup_status=$?
		oc -n "${FIXTURE_NAMESPACE}" delete configmap "${CA_CONFIG_MAP_NAME}" --ignore-not-found --wait=false || cleanup_status=$?
		if [[ "${fixture_namespace_created}" == 1 ]]; then
			oc delete namespace "${FIXTURE_NAMESPACE}" --ignore-not-found --wait=false || cleanup_status=$?
		fi
	fi
	rm -rf "${WORKDIR}"
	if [[ "${cleanup_status}" != 0 && "${status}" == 0 ]]; then status="${cleanup_status}"; fi
	exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ensure_prerequisites() {
	if ! oc get namespace "${FIXTURE_NAMESPACE}" >/dev/null 2>&1; then
		echo ">> Bootstrapping isolated RHBK operator in ${FIXTURE_NAMESPACE}"
		[[ "$(oc auth can-i create namespaces)" == yes ]] || fail "missing permission to create the RHBK fixture namespace"
		[[ "$(oc auth can-i create operatorgroups -n "${FIXTURE_NAMESPACE}")" == yes ]] || fail "missing permission to create an OperatorGroup"
		[[ "$(oc auth can-i create subscriptions -n "${FIXTURE_NAMESPACE}")" == yes ]] || fail "missing permission to create an RHBK Subscription"
		oc create namespace "${FIXTURE_NAMESPACE}"
		fixture_namespace_created=1
		oc label namespace "${FIXTURE_NAMESPACE}" "${LABEL_KEY}=${LABEL_VALUE}"
		cat <<EOF | oc -n "${FIXTURE_NAMESPACE}" apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${RESOURCE_PREFIX}-rhbk
  labels: {${LABEL_KEY}: ${LABEL_VALUE}}
spec:
  targetNamespaces: [${FIXTURE_NAMESPACE}]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${RHBK_SUBSCRIPTION_NAME}
  labels: {${LABEL_KEY}: ${LABEL_VALUE}}
spec:
  channel: ${RHBK_OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: rhbk-operator
  source: ${RHBK_OPERATOR_SOURCE}
  sourceNamespace: ${RHBK_OPERATOR_SOURCE_NAMESPACE}
EOF
	fi
	for _ in $(seq 1 120); do
		if oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1 \
			&& oc get crd keycloakrealmimports.k8s.keycloak.org >/dev/null 2>&1 \
			&& oc -n "${FIXTURE_NAMESPACE}" get csv -o json | "${PYTHON_BIN}" -c '
import json, sys
for item in json.load(sys.stdin)["items"]:
    if item["metadata"]["name"].startswith("rhbk-operator.") and item.get("status", {}).get("phase") == "Succeeded":
        raise SystemExit(0)
raise SystemExit(1)
'; then break; fi
		sleep 5
	done
	oc get crd keycloaks.k8s.keycloak.org >/dev/null || fail "RHBK Keycloak CRD did not become available"
	oc get crd keycloakrealmimports.k8s.keycloak.org >/dev/null || fail "RHBK KeycloakRealmImport CRD did not become available"
	oc -n "${FIXTURE_NAMESPACE}" get csv -o json | "${PYTHON_BIN}" -c '
import json, sys
for item in json.load(sys.stdin)["items"]:
    if item["metadata"]["name"].startswith("rhbk-operator.") and item.get("status", {}).get("phase") == "Succeeded":
        raise SystemExit(0)
raise SystemExit(1)
' || fail "a succeeded RHBK operator is required in ${FIXTURE_NAMESPACE}"
	for resource in secrets configmaps services persistentvolumeclaims deployments routes keycloaks keycloakrealmimports; do
		[[ "$(oc auth can-i create "${resource}" -n "${FIXTURE_NAMESPACE}")" == yes ]] || fail "missing create permission for ${resource} in ${FIXTURE_NAMESPACE}"
	done
}

wait_for_keycloak_statefulset() {
	echo ">> Waiting for Keycloak StatefulSet ${KEYCLOAK_NAME}"
	for _ in $(seq 1 60); do
		if oc -n "${FIXTURE_NAMESPACE}" get "statefulset/${KEYCLOAK_NAME}" >/dev/null 2>&1; then
			return 0
		fi
		sleep 5
	done
	fail "RHBK did not create statefulset/${KEYCLOAK_NAME} within 300 seconds"
}

wait_for_realm_import() {
	local attempts=60
	while (( attempts > 0 )); do
		if oc -n "${FIXTURE_NAMESPACE}" get "keycloakrealmimport/${REALM_IMPORT_NAME}" -o json 2>/dev/null | "${PYTHON_BIN}" -c '
import json, sys
conditions = json.load(sys.stdin).get("status", {}).get("conditions", [])
raise SystemExit(0 if any(c.get("type") == "Done" and str(c.get("status", "")).lower() == "true" for c in conditions) else 1)
'; then return 0; fi
		sleep 5; attempts=$((attempts - 1))
	done
	return 1
}

validate_identity_fixture() {
	# Check the identity-provider contract separately from gateway authorization.
	# The resulting file deliberately contains only stable labels, role/scope data,
	# and non-reversible subject fingerprints: never bearer tokens or credentials.
	OIDC_IDENTITY_ISSUER="${OIDC_ISSUER}" \
	OIDC_IDENTITY_CA_FILE="${CA_CERT_FILE}" \
	OIDC_IDENTITY_ADMIN_PASSWORD="${admin_password}" \
	OIDC_IDENTITY_USER_PASSWORD="${user_password}" \
	OIDC_IDENTITY_USER_B_PASSWORD="${user_b_password}" \
	OIDC_IDENTITY_ADMIN_ROLE="${OPENSHELL_E2E_OIDC_ADMIN_ROLE:-openshell-admin}" \
	OIDC_IDENTITY_USER_ROLE="${OPENSHELL_E2E_OIDC_USER_ROLE:-openshell-user}" \
	OIDC_IDENTITY_SCOPE="${OPENSHELL_E2E_OIDC_EXPECTED_SCOPE:-openshell:all}" \
	OIDC_IDENTITY_SUMMARY="${IDENTITY_SUMMARY}" \
	"${PYTHON_BIN}" "${SCRIPT_DIR}/validate-oidc-identity-fixture.py"
}

echo ">> Validating RHBK prerequisites in ${FIXTURE_NAMESPACE}"
cleanup_enabled=1
ensure_prerequisites

echo ">> Creating per-run Keycloak TLS material"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "${WORKDIR}/ca.key" -out "${CA_CERT_FILE}" -subj "/CN=${RESOURCE_PREFIX}-ca" -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
# OpenSSL limits a CN to 64 bytes; the full OpenShift Route hostname belongs
# in the SAN and can be longer than that.
openssl req -newkey rsa:2048 -nodes -keyout "${WORKDIR}/tls.key" -out "${WORKDIR}/tls.csr" -subj "/CN=${RESOURCE_PREFIX}" >/dev/null 2>&1
openssl x509 -req -days 1 -in "${WORKDIR}/tls.csr" -CA "${CA_CERT_FILE}" -CAkey "${WORKDIR}/ca.key" -CAcreateserial -out "${WORKDIR}/tls.crt" -extensions v3_req -extfile <(printf '[v3_req]\nsubjectAltName=DNS:%s\n' "${KEYCLOAK_ROUTE_HOST}") >/dev/null 2>&1
oc -n "${FIXTURE_NAMESPACE}" create secret tls "${TLS_SECRET_NAME}" --cert="${WORKDIR}/tls.crt" --key="${WORKDIR}/tls.key" --dry-run=client -o yaml | oc label -f - "${LABEL_KEY}=${LABEL_VALUE}" --local -o yaml | oc apply -f -
oc -n "${FIXTURE_NAMESPACE}" create configmap "${CA_CONFIG_MAP_NAME}" --from-file=ca.crt="${CA_CERT_FILE}" --dry-run=client -o yaml | oc label -f - "${LABEL_KEY}=${LABEL_VALUE}" --local -o yaml | oc apply -f -

db_password="$(openssl rand -hex 24)"; admin_password="$(openssl rand -hex 24)"; user_password="$(openssl rand -hex 24)"; user_b_password="$(openssl rand -hex 24)"; client_secret="$(openssl rand -hex 24)"
printf '%s' keycloak > "${WORKDIR}/db-username"
printf '%s' "${db_password}" > "${WORKDIR}/db-password"
printf '%s' "${admin_password}" > "${WORKDIR}/admin-password"
printf '%s' "${user_password}" > "${WORKDIR}/user-password"
printf '%s' "${user_b_password}" > "${WORKDIR}/user-b-password"
printf '%s' "${client_secret}" > "${WORKDIR}/client-secret"
oc -n "${FIXTURE_NAMESPACE}" create secret generic "${DB_SECRET_NAME}" \
	--from-file=username="${WORKDIR}/db-username" --from-file=password="${WORKDIR}/db-password" \
	--dry-run=client -o yaml | oc label -f - "${LABEL_KEY}=${LABEL_VALUE}" --local -o yaml | oc apply -f -
oc -n "${FIXTURE_NAMESPACE}" create secret generic "${FIXTURE_SECRET_NAME}" \
	--from-file=admin-password="${WORKDIR}/admin-password" --from-file=user-password="${WORKDIR}/user-password" \
	--from-file=user-b-password="${WORKDIR}/user-b-password" --from-file=client-secret="${WORKDIR}/client-secret" \
	--dry-run=client -o yaml | oc label -f - "${LABEL_KEY}=${LABEL_VALUE}" --local -o yaml | oc apply -f -

echo ">> Deploying ephemeral PostgreSQL"
cat <<EOF | oc -n "${FIXTURE_NAMESPACE}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${POSTGRES_NAME}
  labels: {${LABEL_KEY}: ${LABEL_VALUE}}
spec:
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Service
metadata:
  name: ${POSTGRES_NAME}
  labels: {${LABEL_KEY}: ${LABEL_VALUE}}
spec:
  selector: {app.kubernetes.io/name: ${POSTGRES_NAME}}
  ports: [{name: postgres, port: 5432, targetPort: postgres}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${POSTGRES_NAME}
  labels: {${LABEL_KEY}: ${LABEL_VALUE}}
spec:
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: ${POSTGRES_NAME}}}
  template:
    metadata:
      labels: {app.kubernetes.io/name: ${POSTGRES_NAME}, ${LABEL_KEY}: ${LABEL_VALUE}}
    spec:
      containers:
        - name: postgres
          image: ${POSTGRES_IMAGE}
          ports: [{name: postgres, containerPort: 5432}]
          env:
            - {name: POSTGRESQL_DATABASE, value: keycloak}
            - name: POSTGRESQL_USER
              valueFrom: {secretKeyRef: {name: ${DB_SECRET_NAME}, key: username}}
            - name: POSTGRESQL_PASSWORD
              valueFrom: {secretKeyRef: {name: ${DB_SECRET_NAME}, key: password}}
          volumeMounts: [{name: data, mountPath: /var/lib/pgsql/data}]
          readinessProbe: {tcpSocket: {port: postgres}}
      volumes: [{name: data, persistentVolumeClaim: {claimName: ${POSTGRES_NAME}}}]
EOF
oc -n "${FIXTURE_NAMESPACE}" rollout status "deployment/${POSTGRES_NAME}" --timeout=300s

echo ">> Deploying RHBK and its passthrough Route"
cat <<EOF | oc -n "${FIXTURE_NAMESPACE}" apply -f -
apiVersion: k8s.keycloak.org/v2beta1
kind: Keycloak
metadata:
  name: ${KEYCLOAK_NAME}
  labels: {${LABEL_KEY}: ${LABEL_VALUE}}
spec:
  instances: 1
  db:
    vendor: postgres
    host: ${POSTGRES_NAME}
    database: keycloak
    usernameSecret: {name: ${DB_SECRET_NAME}, key: username}
    passwordSecret: {name: ${DB_SECRET_NAME}, key: password}
  http: {tlsSecret: ${TLS_SECRET_NAME}}
  hostname: {hostname: ${KEYCLOAK_ROUTE_HOST}}
  ingress: {enabled: false}
  proxy: {headers: xforwarded}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${KEYCLOAK_ROUTE_NAME}
  labels: {${LABEL_KEY}: ${LABEL_VALUE}}
spec:
  host: ${KEYCLOAK_ROUTE_HOST}
  to: {kind: Service, name: ${KEYCLOAK_NAME}-service}
  port: {targetPort: https}
  tls: {termination: passthrough, insecureEdgeTerminationPolicy: Redirect}
EOF
wait_for_keycloak_statefulset
oc -n "${FIXTURE_NAMESPACE}" rollout status "statefulset/${KEYCLOAK_NAME}" --timeout=300s

echo ">> Importing the isolated OpenShell realm"
OIDC_ACCESS_TOKEN_LIFESPAN="${OIDC_ACCESS_TOKEN_LIFESPAN}" OIDC_CLIENT_SESSION_MAX_LIFESPAN="${OIDC_CLIENT_SESSION_MAX_LIFESPAN}" "${PYTHON_BIN}" - "${ROOT}/scripts/keycloak-realm.json" "${REALM_FILE}" <<'PY'
import json
import os
import sys

realm = json.load(open(sys.argv[1]))
realm["accessTokenLifespan"] = int(os.environ["OIDC_ACCESS_TOKEN_LIFESPAN"])
realm["clientSessionMaxLifespan"] = int(os.environ["OIDC_CLIENT_SESSION_MAX_LIFESPAN"])
passwords = {
    "admin@test": "${ADMIN_PASSWORD}",
    "user@test": "${USER_PASSWORD}",
    "user-b@test": "${USER_B_PASSWORD}",
}
for user in realm["users"]:
    user["credentials"][0]["value"] = passwords[user["username"]]
for client in realm["clients"]:
    if client["clientId"] == "openshell-ci":
        client["secret"] = "${CLIENT_SECRET}"
json.dump(realm, open(sys.argv[2], "w"))
PY
REALM_FILE="${REALM_FILE}" REALM_IMPORT_NAME="${REALM_IMPORT_NAME}" KEYCLOAK_NAME="${KEYCLOAK_NAME}" FIXTURE_SECRET_NAME="${FIXTURE_SECRET_NAME}" LABEL_KEY="${LABEL_KEY}" LABEL_VALUE="${LABEL_VALUE}" "${PYTHON_BIN}" - <<'PY' | oc -n "${FIXTURE_NAMESPACE}" apply -f -
import json
import os

print(json.dumps({
    "apiVersion": "k8s.keycloak.org/v2beta1",
    "kind": "KeycloakRealmImport",
    "metadata": {"name": os.environ["REALM_IMPORT_NAME"], "labels": {os.environ["LABEL_KEY"]: os.environ["LABEL_VALUE"]}},
    "spec": {
        "keycloakCRName": os.environ["KEYCLOAK_NAME"],
        "placeholders": {
            "ADMIN_PASSWORD": {"secret": {"name": os.environ["FIXTURE_SECRET_NAME"], "key": "admin-password"}},
            "USER_PASSWORD": {"secret": {"name": os.environ["FIXTURE_SECRET_NAME"], "key": "user-password"}},
            "USER_B_PASSWORD": {"secret": {"name": os.environ["FIXTURE_SECRET_NAME"], "key": "user-b-password"}},
            "CLIENT_SECRET": {"secret": {"name": os.environ["FIXTURE_SECRET_NAME"], "key": "client-secret"}},
        },
        "realm": json.load(open(os.environ["REALM_FILE"])),
    },
}))
PY
wait_for_realm_import || fail "Keycloak realm import did not complete"

echo ">> Waiting for OIDC discovery"
oidc_discovery_ready() {
	"${PYTHON_BIN}" - "${OIDC_ISSUER}/.well-known/openid-configuration" "${CA_CERT_FILE}" <<'PY'
import ssl
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], context=ssl.create_default_context(cafile=sys.argv[2]), timeout=10):
    pass
PY
}
for _ in $(seq 1 60); do
	if oidc_discovery_ready >/dev/null 2>&1; then break; fi
	sleep 5
done
oidc_discovery_ready || fail "Keycloak OIDC discovery did not become ready"

echo ">> Validating Keycloak identity fixture"
validate_identity_fixture || fail "identity-provider fixture validation failed"

echo ">> Deploying OpenShell and seeding provider profiles"
# Provider profiles are an operator-controlled bootstrap artifact. Seed them
# before enforcing OIDC; the final rollout below always disables anonymous use.
NAMESPACE="${OPENSHIFT_NAMESPACE}" RELEASE="${OPENSHIFT_RELEASE}" GATEWAY_NAME="${GATEWAY_NAME}" ROUTE_HOST="${OPENSHIFT_ROUTE_HOST}" OIDC_ISSUER="${OIDC_ISSUER}" OIDC_CA_CERT_FILE="${CA_CERT_FILE}" ALLOW_UNAUTHENTICATED_USERS=true "${DEPLOY_SCRIPT}" deploy --yes
openshell_deployed=1

# openshell gateway add generates local CLI credentials. Keep the test client's
# certificate bundle separate so a CLI refresh cannot replace this run's CA.
mkdir -p "${GATEWAY_MTLS_DIR}"
for certificate in ca.crt tls.crt tls.key; do
	oc -n "${OPENSHIFT_NAMESPACE}" get secret openshell-client-tls \
		-o "jsonpath={.data.${certificate//./\\.}}" | base64 -d > "${GATEWAY_MTLS_DIR}/${certificate}"
done

echo ">> Importing provider profiles required by the OIDC suite"
if ! "${OPENSHELL_BIN:-openshell}" provider profile import --from "${ROOT}/providers" --global; then
	fail "provider profile import failed; run the Konflux e2e image with gateway, supervisor, and sandbox images built from the same commit"
fi

echo ">> Enforcing OIDC-only access"
helm upgrade "${OPENSHIFT_RELEASE}" "${ROOT}/deploy/helm/openshell" \
	--namespace "${OPENSHIFT_NAMESPACE}" \
	--reuse-values \
	--set server.auth.allowUnauthenticatedUsers=false
oc -n "${OPENSHIFT_NAMESPACE}" rollout status "statefulset/${OPENSHIFT_RELEASE}" --timeout=300s

echo ">> Running gateway authorization validation (Python OIDC tests)"
pytest_status=0
OPENSHELL_E2E_OIDC=1 OPENSHELL_E2E_OIDC_SCOPES=1 OPENSHELL_E2E_OIDC_SESSION_LIFECYCLE=1 OPENSHELL_E2E_OIDC_ISSUER="${OIDC_ISSUER}" OPENSHELL_KEYCLOAK_URL="https://${KEYCLOAK_ROUTE_HOST}" OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT="https://${OPENSHIFT_ROUTE_HOST}" OPENSHELL_GATEWAY="${GATEWAY_NAME}" OPENSHELL_E2E_GATEWAY_MTLS_DIR="${GATEWAY_MTLS_DIR}" OPENSHELL_E2E_OIDC_ADMIN_PASSWORD="${admin_password}" OPENSHELL_E2E_OIDC_USER_PASSWORD="${user_password}" OPENSHELL_E2E_OIDC_USER_B_PASSWORD="${user_b_password}" OPENSHELL_E2E_OIDC_CLIENT_SECRET="${client_secret}" SSL_CERT_FILE="${CA_CERT_FILE}" REQUESTS_CA_BUNDLE="${CA_CERT_FILE}" uv run --frozen --no-sync pytest e2e/python/oidc --junitxml="${PYTEST_JUNIT_RAW}" >"${PYTEST_RAW_LOG}" 2>&1 || pytest_status=$?
redact_pytest_artifacts
cat "${PYTEST_LOG}"
if [[ "${pytest_status}" != 0 ]]; then
	echo "ERROR: gateway authorization validation failed after identity fixture preflight" >&2
	exit "${pytest_status}"
fi

echo ">> OIDC validation passed"
