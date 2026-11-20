#!/usr/bin/env bash
# shellcheck disable=SC2329
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Provision the per-run Keycloak fixture. Sourced by odh-oidc-fixture.sh with
# STATE_DIR set; expects the caller to have already sourced common.sh and
# validated the state directory.

# The entrypoint pre-creates the state directory; accept it only when empty
# so a rerun cannot silently mix two runs' state.
if [[ -e "${STATE_DIR}" ]]; then
	[[ -d "${STATE_DIR}" ]] || fixture_fail "state directory ${STATE_DIR} is not a directory"
	[[ -z "$(ls -A "${STATE_DIR}")" ]] || fixture_fail "state directory ${STATE_DIR} is not empty"
else
	mkdir -p "${STATE_DIR}"
fi
chmod 700 "${STATE_DIR}"

fixture_derive_names

if [[ -z "${KUBECONFIG:-}" ]]; then
	KUBECONFIG="${FIXTURE_ROOT}/.kube/config"
	export KUBECONFIG
fi
[[ -f "${KUBECONFIG}" ]] || fixture_fail "kubeconfig not found at ${KUBECONFIG}"
oc whoami >/dev/null || fixture_fail "unable to authenticate to OpenShift"

RETAIN_ON_FAILURE="${OPENSHELL_E2E_RETAIN_ON_FAILURE:-0}"
OIDC_ADMIN_ROLE="${OPENSHELL_E2E_OIDC_ADMIN_ROLE:-openshell-admin}"
OIDC_USER_ROLE="${OPENSHELL_E2E_OIDC_USER_ROLE:-openshell-user}"
OIDC_EXPECTED_SCOPE="${OPENSHELL_E2E_OIDC_EXPECTED_SCOPE:-openshell:all}"
POSTGRES_IMAGE="${OPENSHELL_E2E_POSTGRES_IMAGE:-registry.redhat.io/rhel9/postgresql-16@sha256:565a44d683b390a10a3fe8d2cbbfd899db017821e0012e99aa6c5b37ea4438b5}"

remove_realm_import() {
	local namespace_status
	[[ -f "$(fixture_internal_state_path "${STATE_DIR}")" ]] || return 0
	fixture_load_internal_state "${STATE_DIR}"
	if [[ "${FIXTURE_NAMESPACE_CREATED}" == 1 ]]; then
		fixture_namespace_matches_uid
		namespace_status=$?
		case "${namespace_status}" in
			0) ;;
			1) return 0 ;;
			*) return 1 ;;
		esac
	fi
	fixture_resource_is_owned keycloakrealmimport "${REALM_IMPORT_NAME}" || return 1
	[[ "${FIXTURE_RESOURCE_OWNED}" == 1 ]] || return 0
	fixture_delete_resource_with_uid keycloakrealmimport "${REALM_IMPORT_NAME}" \
		"${FIXTURE_RESOURCE_UID}" || return 1
	fixture_wait_for_resource_absence keycloakrealmimport "${REALM_IMPORT_NAME}"
}

setup_cleanup() {
	local status=$? realm_import_cleanup_status=0
	trap - EXIT INT TERM
	# Never retain credentials or private keys, not even when the fixture is
	# kept for diagnosis: no password, key, or secret may survive in a
	# retained artifact.
	rm -f "${STATE_DIR}/ca.key" "${STATE_DIR}/tls.key" \
		"${STATE_DIR}/tls.csr" "${STATE_DIR}/ca.srl" \
		"${STATE_DIR}/db-username" "${STATE_DIR}/db-password"
	if ! remove_realm_import; then
		realm_import_cleanup_status=1
		echo "ERROR: could not remove the temporary KeycloakRealmImport ${REALM_IMPORT_NAME}; bypassing retention" >&2
	fi
	if [[ "${status}" == 0 ]]; then
		# A successful setup hands the live fixture to the entrypoint. Cleanup
		# happens explicitly after the test phase, not from this EXIT trap.
		exit 0
	fi
	if [[ "${RETAIN_ON_FAILURE}" == 1 && "${realm_import_cleanup_status}" == 0 ]]; then
		echo ">> Retaining OIDC fixture for diagnosis (OPENSHELL_E2E_RETAIN_ON_FAILURE=1); state: ${STATE_DIR}" >&2
		exit "${status}"
	fi
	if [[ "${realm_import_cleanup_status}" == 1 ]]; then
		echo ">> Retention bypassed; retrying ownership-checked fixture cleanup" >&2
	fi
	if [[ -f "$(fixture_internal_state_path "${STATE_DIR}")" ]]; then
		echo ">> Collecting OIDC diagnostics before setup cleanup" >&2
		if ! "${FIXTURE_SCRIPTS_DIR}/odh-oidc-fixture.sh" diagnostics --state-dir "${STATE_DIR}"; then
			echo "WARNING: OIDC setup diagnostics collection failed" >&2
		fi
	fi
	if ! fixture_delete_owned_resources "${STATE_DIR}"; then
		echo "ERROR: OIDC fixture cleanup failed after a setup failure" >&2
		[[ "${status}" != 0 ]] || status=1
	fi
	exit "${status}"
}
trap setup_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Record an initial private run state before touching the cluster so the
# failure trap always knows what this run owns, then update it as soon as the
# namespace decision is made.
fixture_write_internal_state "${STATE_DIR}" 0
if ! oc get namespace "${FIXTURE_NAMESPACE}" >/dev/null 2>&1; then
	echo ">> Creating run-scoped fixture namespace ${FIXTURE_NAMESPACE}"
	[[ "$(oc auth can-i create namespaces)" == yes ]] || fixture_fail "missing permission to create the RHBK fixture namespace"
	# Capture ownership in the create response before making another API call.
	FIXTURE_NAMESPACE_UID="$(oc create namespace "${FIXTURE_NAMESPACE}" -o jsonpath='{.metadata.uid}')"
	[[ -n "${FIXTURE_NAMESPACE_UID}" ]] || fixture_fail "could not record the created fixture namespace UID"
	fixture_write_internal_state "${STATE_DIR}" 1 "${FIXTURE_NAMESPACE_UID}"
	oc label namespace "${FIXTURE_NAMESPACE}" "${LABEL_KEY}=${LABEL_VALUE}"
fi

# Install RHBK through OLM in the run-scoped namespace when the CRDs are not
# already served. The namespace is owned by this fixture unless the caller
# supplied OPENSHELL_E2E_RHBK_NAMESPACE, so an existing shared operator is
# reused and never removed by this lane.
install_rhbk_operator() {
	if oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1 &&
		oc get crd keycloakrealmimports.k8s.keycloak.org >/dev/null 2>&1; then
		return 0
	fi
	if [[ -n "${OPENSHELL_E2E_RHBK_NAMESPACE:-}" ]]; then
		fixture_fail "RHBK CRDs are not served; refusing to install OLM resources in caller-owned namespace ${FIXTURE_NAMESPACE}"
	fi
	cat <<EOF | oc -n "${FIXTURE_NAMESPACE}" create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${RESOURCE_PREFIX}-rhbk
spec:
  targetNamespaces:
    - ${FIXTURE_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
spec:
  channel: ${OPENSHELL_E2E_RHBK_CHANNEL:-stable-v26.6}
  name: rhbk-operator
  source: ${OPENSHELL_E2E_RHBK_CATALOG_SOURCE:-redhat-operators}
  sourceNamespace: openshift-marketplace
EOF
}

install_rhbk_operator

# A Succeeded rhbk-operator CSV must be visible in the fixture namespace.
csv_ready() {
	oc -n "${FIXTURE_NAMESPACE}" get csv -o json 2>/dev/null | "${PYTHON_BIN}" -c '
import json, sys
try:
    items = json.load(sys.stdin)["items"]
except Exception:
    raise SystemExit(1)
for item in items:
    if item["metadata"]["name"].startswith("rhbk-operator.") and item.get("status", {}).get("phase") == "Succeeded":
        raise SystemExit(0)
raise SystemExit(1)
'
}
csv_waited=0
until csv_ready; do
	csv_waited=$((csv_waited + 1))
	if (( csv_waited > 60 )); then
		fixture_fail "a Succeeded RHBK operator CSV did not appear in ${FIXTURE_NAMESPACE} within 300 seconds"
	fi
	sleep 5
done

for resource in secrets configmaps services persistentvolumeclaims deployments routes keycloaks keycloakrealmimports; do
	[[ "$(oc auth can-i create "${resource}" -n "${FIXTURE_NAMESPACE}")" == yes ]] \
		|| fixture_fail "missing create permission for ${resource} in ${FIXTURE_NAMESPACE}"
done

echo ">> Deriving Route hosts from the cluster ingress domain"
OPENSHIFT_APPS_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
[[ -n "${OPENSHIFT_APPS_DOMAIN}" ]] || fixture_fail "could not read the OpenShift apps domain"
KEYCLOAK_ROUTE_HOST="${RESOURCE_PREFIX}-kc.${OPENSHIFT_APPS_DOMAIN}"
GATEWAY_ROUTE_HOST="${ROUTE_HOST:-openshell-${RUN_ID}.${OPENSHIFT_APPS_DOMAIN}}"
OIDC_ISSUER="https://${KEYCLOAK_ROUTE_HOST}/realms/openshell"
OIDC_CA_CERT_FILE="${STATE_DIR}/keycloak-ca.crt"
OIDC_VALUES_FILE="${STATE_DIR}/oidc-values.yaml"

echo ">> Creating per-run Keycloak TLS material"
bash "${FIXTURE_SCRIPTS_DIR}/generate-oidc-tls-material.sh" "${STATE_DIR}" "${KEYCLOAK_ROUTE_HOST}"
	oc -n "${FIXTURE_NAMESPACE}" create secret tls "${TLS_SECRET_NAME}" \
	--cert="${STATE_DIR}/tls.crt" --key="${STATE_DIR}/tls.key" \
	--dry-run=client -o yaml | oc label -f - "${LABEL_KEY}=${LABEL_VALUE}" --local -o yaml | oc create -f -
# The private keys exist only to push the serving certificate into the
# cluster; drop them immediately so no retained state (including
# OPENSHELL_E2E_RETAIN_ON_FAILURE) ever contains private key material.
rm -f "${STATE_DIR}/ca.key" "${STATE_DIR}/tls.key"
oc -n "${FIXTURE_NAMESPACE}" create configmap "${FIXTURE_CA_CONFIG_MAP_NAME}" \
	--from-file=ca.crt="${OIDC_CA_CERT_FILE}" \
	--dry-run=client -o yaml | oc label -f - "${LABEL_KEY}=${LABEL_VALUE}" --local -o yaml | oc create -f -

echo ">> Deploying ephemeral PostgreSQL"
# The database password is generated in memory and passed through a file
# descriptor: it is never written to the state directory or exposed in oc's
# argument vector.
db_password="$(openssl rand -hex 24)"
oc -n "${FIXTURE_NAMESPACE}" create secret generic "${DB_SECRET_NAME}" \
	--from-literal=username=keycloak \
	--from-file=password=<(printf '%s' "${db_password}") \
	--dry-run=client -o yaml | oc label -f - "${LABEL_KEY}=${LABEL_VALUE}" --local -o yaml | oc create -f -
cat <<EOF | oc -n "${FIXTURE_NAMESPACE}" create -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${POSTGRES_NAME}
  labels: {${LABEL_KEY}: "${LABEL_VALUE}"}
spec:
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Service
metadata:
  name: ${POSTGRES_NAME}
  labels: {${LABEL_KEY}: "${LABEL_VALUE}"}
spec:
  selector: {app.kubernetes.io/name: ${POSTGRES_NAME}}
  ports: [{name: postgres, port: 5432, targetPort: postgres}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${POSTGRES_NAME}
  labels: {${LABEL_KEY}: "${LABEL_VALUE}"}
spec:
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: ${POSTGRES_NAME}}}
  template:
    metadata:
      labels: {app.kubernetes.io/name: ${POSTGRES_NAME}, ${LABEL_KEY}: "${LABEL_VALUE}"}
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

echo ">> Deploying RHBK Keycloak and its passthrough Route"
cat <<EOF | oc -n "${FIXTURE_NAMESPACE}" create -f -
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: ${KEYCLOAK_NAME}
  labels: {${LABEL_KEY}: "${LABEL_VALUE}"}
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
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${KEYCLOAK_ROUTE_NAME}
  labels: {${LABEL_KEY}: "${LABEL_VALUE}"}
spec:
  host: ${KEYCLOAK_ROUTE_HOST}
  to: {kind: Service, name: ${KEYCLOAK_NAME}-service}
  port: {targetPort: https}
  tls: {termination: passthrough, insecureEdgeTerminationPolicy: Redirect}
EOF
echo ">> Waiting for the Keycloak StatefulSet"
keycloak_waited=0
until oc -n "${FIXTURE_NAMESPACE}" get "statefulset/${KEYCLOAK_NAME}" >/dev/null 2>&1; do
	keycloak_waited=$((keycloak_waited + 1))
	if (( keycloak_waited > 60 )); then
		fixture_fail "RHBK did not create statefulset/${KEYCLOAK_NAME} within 300 seconds"
	fi
	sleep 5
done
oc -n "${FIXTURE_NAMESPACE}" rollout status "statefulset/${KEYCLOAK_NAME}" --timeout=300s

echo ">> Importing the OpenShell realm"
REALM_FILE="${FIXTURE_ROOT}/../scripts/keycloak-realm.json" REALM_IMPORT_NAME="${REALM_IMPORT_NAME}" \
	KEYCLOAK_NAME="${KEYCLOAK_NAME}" LABEL_KEY="${LABEL_KEY}" LABEL_VALUE="${LABEL_VALUE}" \
	"${PYTHON_BIN}" - <<'PY' | oc -n "${FIXTURE_NAMESPACE}" create -f -
import json
import os

realm = json.load(open(os.environ["REALM_FILE"]))
passwords = {
    "admin@test": os.environ["OPENSHELL_E2E_OIDC_ADMIN_PASSWORD"],
    "user@test": os.environ["OPENSHELL_E2E_OIDC_USER_PASSWORD"],
    "user-b@test": os.environ["OPENSHELL_E2E_OIDC_USER_B_PASSWORD"],
}
for user in realm["users"]:
    if user["username"] in passwords:
        user["credentials"][0]["value"] = passwords[user["username"]]
for client in realm["clients"]:
    if client.get("clientId") == "openshell-ci":
        client["secret"] = os.environ["OPENSHELL_E2E_OIDC_CI_CLIENT_SECRET"]
print(json.dumps({
    "apiVersion": "k8s.keycloak.org/v2alpha1",
    "kind": "KeycloakRealmImport",
    "metadata": {
        "name": os.environ["REALM_IMPORT_NAME"],
        "labels": {os.environ["LABEL_KEY"]: os.environ["LABEL_VALUE"]},
    },
    "spec": {
        "keycloakCRName": os.environ["KEYCLOAK_NAME"],
        "realm": realm,
    },
}))
PY
echo ">> Waiting for the realm import"
realm_waited=0
until oc -n "${FIXTURE_NAMESPACE}" get "keycloakrealmimport/${REALM_IMPORT_NAME}" -o json 2>/dev/null | "${PYTHON_BIN}" -c '
import json, sys
try:
    conditions = json.load(sys.stdin).get("status", {}).get("conditions", [])
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if any(c.get("type") == "Done" and str(c.get("status", "")).lower() == "true" for c in conditions) else 1)
'; do
	realm_waited=$((realm_waited + 1))
	if (( realm_waited > 60 )); then
		fixture_fail "Keycloak realm import did not complete within 300 seconds"
	fi
	sleep 5
done
if ! remove_realm_import; then
	fixture_fail "could not remove the temporary KeycloakRealmImport"
fi

echo ">> Waiting for OIDC discovery at ${OIDC_ISSUER}"
oidc_discovery_ready() {
	"${PYTHON_BIN}" - "${OIDC_ISSUER}/.well-known/openid-configuration" "${OIDC_CA_CERT_FILE}" <<'PY'
import ssl
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], context=ssl.create_default_context(cafile=sys.argv[2]), timeout=10):
    pass
PY
}
discovery_waited=0
until oidc_discovery_ready >/dev/null 2>&1; do
	discovery_waited=$((discovery_waited + 1))
	if (( discovery_waited > 60 )); then
		fixture_fail "Keycloak OIDC discovery did not become ready within 300 seconds"
	fi
	sleep 5
done

echo ">> Writing the temporary OIDC values overlay and run state"
cat > "${OIDC_VALUES_FILE}" <<EOF
# Generated per-run by the ODH OIDC fixture for run ${RUN_ID}; temporary, mode 0600.
gatewayConfig:
  openshell.gateway.oidc:
    issuer: ${OIDC_ISSUER}
    audience: openshell-cli
    roles_claim: realm_access.roles
    admin_role: ${OIDC_ADMIN_ROLE}
    user_role: ${OIDC_USER_ROLE}
    scopes_claim: scope
server:
  oidc:
    caConfigMapName: ${FIXTURE_CA_CONFIG_MAP_NAME}
EOF
chmod 600 "${OIDC_VALUES_FILE}"
# The operational environment deliberately records no credential. The
# entrypoint owns per-run credentials in memory and passes them to setup and
# the identity preflight by environment; no retained state ever contains a
# password.
{
	# fixture.env is sourced by the entrypoint too; serialize values as shell
	# words so route and namespace overrides cannot become shell syntax.
	printf 'export OPENSHELL_E2E_OIDC_ISSUER=%q\n' "${OIDC_ISSUER}"
	printf 'export OPENSHELL_KEYCLOAK_URL=%q\n' "https://${KEYCLOAK_ROUTE_HOST}"
	printf 'export OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT=%q\n' "https://${GATEWAY_ROUTE_HOST}"
	printf 'export ROUTE_HOST=%q\n' "${GATEWAY_ROUTE_HOST}"
	printf 'export OPENSHELL_E2E_RHBK_NAMESPACE=%q\n' "${FIXTURE_NAMESPACE}"
	printf 'export OPENSHELL_E2E_OIDC_CA_CERT_FILE=%q\n' "${OIDC_CA_CERT_FILE}"
	printf 'export OPENSHELL_E2E_OIDC_CA_CONFIG_MAP_NAME=%q\n' "${FIXTURE_CA_CONFIG_MAP_NAME}"
	printf 'export OPENSHELL_E2E_OIDC_VALUES_FILE=%q\n' "${OIDC_VALUES_FILE}"
	printf 'export OIDC_IDENTITY_ADMIN_ROLE=%q\n' "${OIDC_ADMIN_ROLE}"
	printf 'export OIDC_IDENTITY_USER_ROLE=%q\n' "${OIDC_USER_ROLE}"
	printf 'export OIDC_IDENTITY_SCOPE=%q\n' "${OIDC_EXPECTED_SCOPE}"
} > "$(fixture_operational_env_path "${STATE_DIR}")"
chmod 600 "$(fixture_operational_env_path "${STATE_DIR}")"
echo ">> OIDC fixture ready (namespace ${FIXTURE_NAMESPACE}, issuer ${OIDC_ISSUER})"
exit 0
