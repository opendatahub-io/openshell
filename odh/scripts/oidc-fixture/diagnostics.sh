#!/usr/bin/env bash
# shellcheck disable=SC2329
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Capture redacted diagnostics for a failed OIDC run, one directory per
# component. Sourced by odh-oidc-fixture.sh with STATE_DIR set; expects the
# caller to have already sourced common.sh.
#
# Each component knows its own queries and owns its subdirectory under the
# diagnostics root; adding a component means adding one function and one
# entry in OIDC_DIAGNOSTIC_COMPONENTS. Every captured artifact passes through
# the redactor before it is retained.

[[ -f "$(fixture_internal_state_path "${STATE_DIR}")" ]] \
	|| fixture_fail "no state.env in ${STATE_DIR}; nothing recorded for this run"
fixture_load_internal_state "${STATE_DIR}"

RESULTS_DIR="${OPENSHELL_E2E_RESULTS_DIR:-${FIXTURE_ROOT}/results}"
DIAGNOSTICS_DIR="${RESULTS_DIR}/oidc-${OPENSHELL_E2E_RUN_ID}-diagnostics"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Run one command and retain its redacted output for a component.
capture() {
	local component="$1" name="$2"
	shift 2
	local destination="${DIAGNOSTICS_DIR}/${component}/${name}"
	local raw="${WORK}/${component}-${name}.raw"
	mkdir -p "${DIAGNOSTICS_DIR}/${component}"
	"$@" >"${raw}" 2>&1 || true
	"${PYTHON_BIN}" "${FIXTURE_SCRIPTS_DIR}/redact-oidc-artifact.py" "${raw}" "${destination}"
}

# Retain redacted logs for every pod matching a label selector.
capture_pod_logs() {
	local component="$1" namespace="$2" selector="$3" pod
	while IFS= read -r pod; do
		[[ -n "${pod}" ]] || continue
		capture "${component}" "pod-${pod}.log" \
			oc -n "${namespace}" logs "pod/${pod}" --all-containers --tail=300
	done < <(oc -n "${namespace}" get pods -l "${selector}" -o name 2>/dev/null \
		| sed 's|^pod/||' || true)
}

diagnostics_keycloak() {
	capture keycloak resources.txt \
		oc -n "${FIXTURE_NAMESPACE}" get keycloak,keycloakrealmimport,deploy,statefulset,pod,service,pvc,route \
		-l "${LABEL_KEY}=${LABEL_VALUE}" -o wide
	capture keycloak events.txt \
		oc -n "${FIXTURE_NAMESPACE}" get events --sort-by=.lastTimestamp
	capture keycloak logs.txt \
		oc -n "${FIXTURE_NAMESPACE}" logs "statefulset/${KEYCLOAK_NAME}" --all-containers --tail=300
}

diagnostics_postgres() {
	capture postgres logs.txt \
		oc -n "${FIXTURE_NAMESPACE}" logs "deployment/${POSTGRES_NAME}" --all-containers --tail=300
}

diagnostics_gateway() {
	capture gateway resources.txt \
		oc -n "${GATEWAY_NAMESPACE}" get pods,route -o wide
	capture gateway events.txt \
		oc -n "${GATEWAY_NAMESPACE}" get events --sort-by=.lastTimestamp
	capture gateway manifests.yaml \
		oc -n "${GATEWAY_NAMESPACE}" get deploy,statefulset,service,route -o yaml
	capture_pod_logs gateway "${GATEWAY_NAMESPACE}" \
		"app.kubernetes.io/name=openshell,app.kubernetes.io/instance=${GATEWAY_RELEASE}"
}

diagnostics_supervisor() {
	capture_pod_logs supervisor "${GATEWAY_NAMESPACE}" "openshell.ai/component=supervisor"
	# The shared chart supervisor uses standard Kubernetes app labels; the
	# openshell.ai selector above is used by per-sandbox supervisor pods.
	capture_pod_logs supervisor "${GATEWAY_NAMESPACE}" \
		"app.kubernetes.io/name=openshell-supervisor,app.kubernetes.io/instance=${GATEWAY_RELEASE},app.kubernetes.io/component=supervisor"
}

diagnostics_sandbox() {
	capture_pod_logs sandbox "${GATEWAY_NAMESPACE}" "openshell.ai/boundary-role=workload"
}

diagnostics_test_run() {
	local report
	for report in \
		"${RESULTS_DIR}"/e2e-odh-oidc-*.xml \
		"${RESULTS_DIR}"/oidc-*-identity.json \
		"${RESULTS_DIR}"/oidc-*-pytest.log; do
		[[ -f "${report}" ]] || continue
		capture test-run "$(basename "${report}")" cat "${report}"
	done
}

OIDC_DIAGNOSTIC_COMPONENTS="keycloak postgres gateway supervisor sandbox test_run"
for component in ${OIDC_DIAGNOSTIC_COMPONENTS}; do
	"diagnostics_${component}"
done
echo ">> OIDC diagnostics written to ${DIAGNOSTICS_DIR}"
exit 0
