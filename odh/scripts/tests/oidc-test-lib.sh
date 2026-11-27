#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Shared OpenShift mock and fixture helpers for the cluster-free OIDC tests.

oidc_test_init() {
# ── Fixture behavior with a mocked oc ───────────────────────────────────────

MOCK_BIN="${WORKDIR}/mock-bin"
OC_LOG="${WORKDIR}/oc.log"
APPLY_MANIFESTS="${WORKDIR}/applied-manifests.yaml"
KUBECONFIG_FILE="${WORKDIR}/kubeconfig"
NAMESPACE_DELETE_MARKER="${WORKDIR}/namespace-delete-complete"
CREATED_RESOURCES="${WORKDIR}/created-resources"
RHBK_OLM_MARKER="${WORKDIR}/rhbk-olm-created"
mkdir -p "${MOCK_BIN}"
: > "${OC_LOG}"
: > "${APPLY_MANIFESTS}"
: > "${CREATED_RESOURCES}"
: > "${KUBECONFIG_FILE}"

cat > "${MOCK_BIN}/oc" <<OC
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${OC_LOG}"
args=("\$@")
joined=" \${args[*]} "
record_manifest_resources() {
  local kind="" in_metadata=0 line name
  while IFS= read -r line; do
    if [[ "\${line}" == kind:\ * ]]; then
      kind="\${line#kind: }"
      in_metadata=0
    elif [[ "\${line}" == metadata: ]]; then
      in_metadata=1
    elif [[ "\${line}" != " "* ]]; then
      in_metadata=0
    elif (( in_metadata )) && [[ "\${line}" == "  name: "* ]]; then
      name="\${line#  name: }"
      printf '%s|%s\n' "\${kind}" "\${name}" >> "${CREATED_RESOURCES}"
      in_metadata=0
    fi
  done
}
if [[ "\${joined}" == *" apply -f -"* || "\${joined}" == *" create -f -"* ]]; then
	if [[ "\${OC_MOCK_APPLY_STATUS:-0}" != 0 ]]; then
		exit "\${OC_MOCK_APPLY_STATUS}"
	fi
	manifest="\$(cat)"
	printf '%s\n' "\${manifest}" >> "${APPLY_MANIFESTS}"
	printf '\n---\n' >> "${APPLY_MANIFESTS}"
	record_manifest_resources <<<"\${manifest}"
	if grep -Fq 'kind: OperatorGroup' <<<"\${manifest}"; then
		: > "${RHBK_OLM_MARKER}"
	fi
	if grep -Fq 'KeycloakRealmImport' <<<"\${manifest}" &&
		! grep -Fq 'KeycloakRealmImport|' "${CREATED_RESOURCES}"; then
		printf 'KeycloakRealmImport|openshell-oidc-%s-realm\n' "\${OPENSHELL_E2E_RUN_ID}" >> "${CREATED_RESOURCES}"
	fi
	exit 0
fi
if [[ "\${joined}" == *" whoami "* ]]; then echo test-user; exit 0; fi
if [[ "\${joined}" == *" get namespace "* && "\${joined}" == *"jsonpath={.metadata.uid}"* ]]; then
	[[ -f "${NAMESPACE_DELETE_MARKER}" ]] && exit 0
		[[ "\${OC_MOCK_NAMESPACE_EMPTY_UID:-0}" == 1 ]] && exit 0
	printf '%s\n' "\${OC_MOCK_NAMESPACE_UID:-fixture-namespace-uid}"
	exit 0
fi
if [[ "\${joined}" == *" get namespace "* ]]; then
	[[ -f "${NAMESPACE_DELETE_MARKER}" ]] && exit 0
	if [[ "\${OC_MOCK_NAMESPACE_EXISTS:-1}" == 0 ]]; then
		printf 'namespace/fixture\n'
		exit 0
	fi
	exit "\${OC_MOCK_NAMESPACE_EXISTS:-1}"
fi
	if [[ "\${joined}" == *" get crd "* ]]; then
		if [[ "\${OC_MOCK_CRD_STATUS:-0}" != 0 && -f "${RHBK_OLM_MARKER}" ]]; then
			exit 0
		fi
		exit "\${OC_MOCK_CRD_STATUS:-0}"
	fi
	if [[ "\${joined}" == *" get "* && "\${joined}" == *" -o name"* && "\${joined}" != *"get pods"* ]]; then
		if [[ "\${OC_MOCK_FOREIGN_ROUTE:-0}" == 1 ]]; then
			exit 0
		fi
		requested_kind="\${args[3]:-}"
		requested_name="\${args[4]:-}"
		case "\${requested_kind}" in
			keycloakrealmimport) resource_kind=KeycloakRealmImport ;;
			keycloak) resource_kind=Keycloak ;;
			route) resource_kind=Route ;;
			deployment) resource_kind=Deployment ;;
			service) resource_kind=Service ;;
			pvc) resource_kind=PersistentVolumeClaim ;;
			secret) resource_kind=Secret ;;
			configmap) resource_kind=ConfigMap ;;
			*) resource_kind="\${requested_kind}" ;;
		esac
		if grep -Fxq "\${resource_kind}|\${requested_name}" "${CREATED_RESOURCES}"; then
			printf '%s/%s\n' "\${requested_kind}" "\${requested_name}"
		fi
		exit 0
	fi
	if [[ "\${joined}" == *"keycloakrealmimport/"* && "\${joined}" == *"-o json"* ]]; then
		printf '{"status":{"conditions":[{"type":"Done","status":"True"}]} }\n'
		exit 0
	fi
	if [[ "\${args[2]:-}" == get && "\${args[3]:-}" == keycloakrealmimport &&
		"\${args[4]:-}" == "openshell-oidc-\${OPENSHELL_E2E_RUN_ID}-realm" &&
		"\${joined}" == *" --ignore-not-found "* && "\${joined}" == *" -o json"* ]]; then
		if grep -Fxq "KeycloakRealmImport|\${args[4]}" "${CREATED_RESOURCES}"; then
			printf '{"metadata":{"name":"%s","uid":"uid-%s","labels":{"openshell.nvidia.com/oidc-run":"%s"}}}\n' \
				"\${args[4]}" "\${args[4]}" "\${OC_MOCK_FALLBACK_LABEL:-\${OPENSHELL_E2E_RUN_ID}}"
		fi
		exit 0
	fi
if [[ "\${joined}" == *" ingresses.config/cluster "* ]]; then printf apps.example.test; exit 0; fi
if [[ "\${OC_MOCK_VERIFY_READ_STATUS:-0}" != 0 && "\${joined}" == *" get keycloak "* && "\${joined}" == *" --ignore-not-found "* ]]; then
	exit "\${OC_MOCK_VERIFY_READ_STATUS}"
fi
# Match the API-server/client behavior that the ownership regression depends
# on: oc rejects a resource name combined with a label selector.
if [[ "\${joined}" == *" -l openshell.nvidia.com/oidc-run="* ]] &&
	[[ "\${joined}" =~ get[[:space:]]+[a-z]+[[:space:]]+openshell- ]]; then
	echo 'name cannot be provided when a selector is specified' >&2
	exit 97
fi
if [[ "\${joined}" == *" get "* && "\${joined}" == *" -l openshell.nvidia.com/oidc-run="* && "\${joined}" == *" --ignore-not-found "* ]]; then
	if [[ "\${args[3]:-}" == "\${OC_MOCK_EMPTY_OWNERSHIP_KIND:-}" &&
		"\${joined}" == *" -o json"* ]]; then
		exit 0
	fi
	if [[ "\${OC_MOCK_FOREIGN_ROUTE:-0}" == 1 && "\${joined}" == *" get route "* ]]; then
		if [[ "\${joined}" == *" -o json"* ]]; then
			printf '{"items":[]}\n'
			exit 0
		else
			exit 0
		fi
	fi
	if [[ "\${joined}" == *" -o json"* ]]; then
		printf '{"items":['
		first=1
		requested_kind="\${args[3]:-}"
		if [[ "\${requested_kind}" == keycloakrealmimport ]]; then
			printf '{"metadata":{"name":"openshell-oidc-%s-realm","uid":"uid-openshell-oidc-%s-realm","labels":{"openshell.nvidia.com/oidc-run":"%s"}}}' \
				"\${OPENSHELL_E2E_RUN_ID}" "\${OPENSHELL_E2E_RUN_ID}" "\${OPENSHELL_E2E_RUN_ID}"
			first=0
		fi
		while IFS='|' read -r resource_kind resource_name; do
			[[ -n "\${resource_kind}" ]] || continue
			case "\${resource_kind}" in
				KeycloakRealmImport) resource_kind=keycloakrealmimport ;;
				Keycloak) resource_kind=keycloak ;;
				Route) resource_kind=route ;;
				Deployment) resource_kind=deployment ;;
				Service) resource_kind=service ;;
				PersistentVolumeClaim) resource_kind=pvc ;;
				Secret) resource_kind=secret ;;
				ConfigMap) resource_kind=configmap ;;
				*) continue ;;
			esac
			requested_kind="\${args[3]:-}"
			[[ "\${resource_kind}" == "\${requested_kind}" ]] || continue
			(( first )) || printf ','
			printf '{"metadata":{"name":"%s","uid":"uid-%s","labels":{"openshell.nvidia.com/oidc-run":"%s"}}}' \
				"\${resource_name}" "\${resource_name}" "\${OPENSHELL_E2E_RUN_ID}"
			first=0
		done < "${CREATED_RESOURCES}"
		printf ']}\n'
	else
		printf 'owned/resource\n'
	fi
	exit 0
fi
if [[ "\${joined}" == *" get csv "* ]]; then
	printf '{"items":[{"metadata":{"name":"rhbk-operator.v26.6.0"},"status":{"phase":"Succeeded"}}]}\n'
	exit 0
fi
if [[ "\${joined}" == *" auth can-i "* ]]; then echo yes; exit 0; fi
if [[ "\${joined}" == *" create namespace "* ]]; then
	if [[ "\${joined}" == *" -o jsonpath="* ]]; then printf 'fixture-namespace-uid'; else printf 'apiVersion: v1\n'; fi
	exit 0
fi
if [[ "\${joined}" == *" create secret "* ]]; then
	secret_name=""
	for ((i=0; i<\${#args[@]}; i++)); do
		if [[ "\${args[i]}" == tls || "\${args[i]}" == generic ]]; then
			secret_name="\${args[i+1]:-}"
			break
		fi
	done
	[[ -n "\${secret_name}" ]] && printf 'Secret|%s\n' "\${secret_name}" >> "${CREATED_RESOURCES}"
	exit 0
fi
if [[ "\${joined}" == *" delete --raw "* ]]; then
	path=""
	for arg in "\${args[@]}"; do
		if [[ "\${arg}" == /api/* || "\${arg}" == /apis/* ]]; then
			path="\${arg}"
			break
		fi
	done
	[[ -n "\${path}" ]] || exit 98
	name="\${path##*/}"
	resource="\${path%/\${name}}"
	kind="\${resource##*/}"
	case "\${kind}" in
		keycloakrealmimports) kind=keycloakrealmimport ;;
		keycloaks) kind=keycloak ;;
		persistentvolumeclaims) kind=pvc ;;
		*) kind="\${kind%s}" ;;
	esac
	printf 'delete %s %s\n' "\${kind}" "\${name}" >> "${OC_LOG}"
	if [[ "\${kind}" == keycloakrealmimport && "\${OC_MOCK_REALM_IMPORT_DELETE_STATUS:-0}" != 0 ]]; then
		exit "\${OC_MOCK_REALM_IMPORT_DELETE_STATUS}"
	fi
	if [[ "\${kind}" == namespace && "\${OC_MOCK_NAMESPACE_DELETE_STATUS:-0}" != 0 ]]; then
		exit "\${OC_MOCK_NAMESPACE_DELETE_STATUS}"
	fi
	if [[ "\${kind}" == namespace ]]; then
		: > "${NAMESPACE_DELETE_MARKER}"
		exit 0
	fi
	awk -F'|' -v k="\${kind}" -v n="\${name}" 'BEGIN{k_lc=tolower(k)} {s1=tolower(\$1); if(s1 != k_lc || \$2 != n) print}' "${CREATED_RESOURCES}" > "${CREATED_RESOURCES}.next"
	mv "${CREATED_RESOURCES}.next" "${CREATED_RESOURCES}"
	exit 0
fi
if [[ "\${joined}" == *" delete namespace "* ]]; then
	if [[ "\${OC_MOCK_NAMESPACE_DELETE_STATUS:-0}" == 0 ]]; then
		: > "${NAMESPACE_DELETE_MARKER}"
	fi
	exit "\${OC_MOCK_NAMESPACE_DELETE_STATUS:-0}"
fi
	if [[ "\${joined}" == *" delete keycloakrealmimport "* ]]; then
		exit "\${OC_MOCK_REALM_IMPORT_DELETE_STATUS:-0}"
	fi
if [[ "\${joined}" == *" label namespace "* ]]; then exit "\${OC_MOCK_LABEL_STATUS:-0}"; fi
if [[ "\${joined}" == *" label "* ]]; then cat; exit 0; fi
if [[ "\${joined}" == *" rollout status "* ]]; then exit "\${OC_MOCK_ROLLOUT_STATUS:-0}"; fi
if [[ "\${joined}" == *"get pods"* && "\${joined}" == *"-o name"* ]]; then
	case "\${joined}" in
		*"openshell.ai/component=supervisor"*) printf 'pod/sup-pod-1\n' ;;
		*"app.kubernetes.io/name=openshell-supervisor"*) printf 'pod/shared-sup-pod-1\n' ;;
		*"openshell.ai/boundary-role=workload"*) printf 'pod/sbx-pod-1\n' ;;
		*"app.kubernetes.io/name=openshell"*) printf 'pod/gw-pod-1\n' ;;
		*) exit 0 ;;
	esac
	exit 0
fi
if [[ "\${joined}" == *" get pods -l openshell.ai/component=supervisor"* ]]; then printf 'pod/sup-pod-1\n'; exit 0; fi
if [[ "\${joined}" == *" get pods -l app.kubernetes.io/name=openshell-supervisor,"* ]]; then printf 'pod/shared-sup-pod-1\n'; exit 0; fi
if [[ "\${joined}" == *" get pods -l openshell.ai/boundary-role=workload"* ]]; then printf 'pod/sbx-pod-1\n'; exit 0; fi
if [[ "\${joined}" == *" logs "* ]]; then
	printf 'authorization: Bearer diagnostic-token-secret\n'
	exit 0
fi
exit 0
OC
chmod +x "${MOCK_BIN}/oc"

# Called by the sourced test script after this helper initializes the mock.
# shellcheck disable=SC2329
run_fixture_setup() {
	local state_dir="$1"
	local revocation_enabled="${RUN_FIXTURE_REVOCATION_ENABLED:-1}"
	local python_bin="${RUN_FIXTURE_PYTHON_BIN:-${PYTHON_TEST_BIN}}"
	shift
	rm -f "${NAMESPACE_DELETE_MARKER}"
	rm -f "${RHBK_OLM_MARKER}"
	env "$@" \
		PATH="${MOCK_BIN}:${PATH}" \
		KUBECONFIG="${KUBECONFIG_FILE}" \
		PYTHON_BIN="${python_bin}" \
		OPENSHELL_E2E_OIDC_ADMIN_PASSWORD="fixture-admin-password" \
		OPENSHELL_E2E_OIDC_USER_PASSWORD="fixture-user-password" \
		OPENSHELL_E2E_OIDC_USER_B_PASSWORD="fixture-user-b-password" \
		OPENSHELL_E2E_OIDC_CI_CLIENT_SECRET="fixture-ci-client-secret" \
		OPENSHELL_E2E_OIDC_REVOCATION_ENABLED="${revocation_enabled}" \
		OPENSHELL_E2E_OIDC_REVOCATION_CLIENT_SECRET="fixture-revocation-client-secret" \
		OPENSHELL_E2E_OIDC_REVOCATION_USER_PASSWORD="fixture-revocation-user-password" \
		OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_ATTEMPTS=1 \
		OPENSHELL_E2E_OIDC_CLEANUP_VERIFY_SLEEP=0 \
		OPENSHELL_E2E_RESULTS_DIR="${WORKDIR}/results" \
		"${FIXTURE}" setup --state-dir "${state_dir}" >"${WORKDIR}/fixture-run.log" 2>&1
}
}
