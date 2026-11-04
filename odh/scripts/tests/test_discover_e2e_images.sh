#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Shell test harness for discover_e2e_images and entrypoint contracts.
# Uses a fake oc to simulate cluster responses without a live cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${SCRIPTS_DIR}/../.." && pwd)"
ENTRYPOINT="${SCRIPTS_DIR}/e2e-odh-entrypoint.sh"

# Exercise discovery directly as well as through the real entrypoint below.
FUNC_DEF="$(sed -n '/^e2e_discovery_oc()/,/^}/p; /^discover_e2e_images()/,/^}/p' "${ENTRYPOINT}")"
if [[ -z "${FUNC_DEF}" ]]; then
	echo "ERROR: could not extract discover_e2e_images from ${ENTRYPOINT}" >&2
	exit 2
fi
eval "${FUNC_DEF}"

passed=0
failed=0
errors=()

run_test() {
	local name="$1"
	shift
	local rc
	# Do not put the test function in an if/|| condition: that disables errexit
	# throughout its body and can turn failed assertions into passing tests.
	set +e
	(
		set -euo pipefail
		trap teardown EXIT
		"$@"
	)
	rc=$?
	set -e
	if [[ "${rc}" == 0 ]]; then
		((passed+=1))
		echo "  PASS: ${name}"
	else
		((failed+=1))
		errors+=("${name}")
		echo "  FAIL: ${name}"
	fi
}

# ---------------------------------------------------------------------------
# Fake oc infrastructure
# ---------------------------------------------------------------------------
WORK_DIR=""
ORIG_PATH="${PATH}"
TEST_PYTHON="${PYTHON_BIN:-$(command -v python3)}"

setup() {
	WORK_DIR="$(mktemp -d)"
	# Default: OLM API present.
	echo "clusterserviceversions.operators.coreos.com" > "${WORK_DIR}/api-resources"
	# Default: no CSVs.
	: > "${WORK_DIR}/csv-list"
	# Default: empty env and relatedImages.
	: > "${WORK_DIR}/csv-env"
	: > "${WORK_DIR}/csv-related"
	: > "${WORK_DIR}/calls"
	# Unset image env vars.
	unset GATEWAY_IMAGE SANDBOX_IMAGE SUPERVISOR_IMAGE IMAGE_TAG GATEWAY_IMAGE_DIGEST
	unset OPENSHELL_E2E_REPORT_MERGER OPENSHELL_E2E_REPLACE_EXISTING OPENSHELL_E2E_DEPLOY_STATE_DIR
	export PYTHON_BIN="${TEST_PYTHON}"
	export KUBECONFIG="${WORK_DIR}/kubeconfig"
	: > "${KUBECONFIG}"
	export XDG_CONFIG_HOME="${WORK_DIR}/config"
	export OPENSHELL_E2E_RESULTS_DIR="${WORK_DIR}/results"
	export OPENSHELL_E2E_RUN_ID="discovery-test"
	export OPENSHELL_E2E_DEPLOY_GATEWAY=1
	export NAMESPACE=openshell RELEASE=openshell GATEWAY_NAME=discovery-test
	export ROUTE_HOST=gateway.example.test

	# Put our fake oc first in PATH.
	mkdir -p "${WORK_DIR}/bin"
	cat > "${WORK_DIR}/bin/oc" <<'FAKEOC'
#!/usr/bin/env bash
set -euo pipefail
WORK="${FAKE_OC_WORK_DIR}"
printf 'oc|%s\n' "$*" >> "${WORK}/calls"
stage=other
if [[ "$1" == api-resources && "$*" == *operators.coreos.com* ]]; then
	stage=api
elif [[ "$1" == get && "$2" == clusterserviceversions.operators.coreos.com ]]; then
	if [[ "${3:-}" == --all-namespaces ]]; then stage=list; else stage=images; fi
fi
count=0
if [[ -f "${WORK}/count-${stage}" ]]; then read -r count < "${WORK}/count-${stage}"; fi
count=$((count + 1))
printf '%s\n' "${count}" > "${WORK}/count-${stage}"
if [[ -f "${WORK}/error-stage" && "$(cat "${WORK}/error-stage")" == "${stage}" ]]; then
	limit="$(cat "${WORK}/failures")"
	if [[ "${count}" -le "${limit}" ]]; then
		echo 'partial output from failed query'
		cat "${WORK}/error-message" >&2
		exit 1
	fi
fi
if [[ "$1" == "api-resources" ]]; then
	if [[ "$*" == *route.openshift.io* ]]; then echo routes; exit 0; fi
	cat "${WORK}/api-resources"
	exit 0
fi
if [[ "$1" == "get" && "$2" == "clusterserviceversions.operators.coreos.com" ]]; then
	if [[ "${3:-}" == "--all-namespaces" ]]; then
		cat "${WORK}/csv-list"
		exit 0
	fi
	# Require both projections in a single fetch, and emit their source tags.
	for arg in "$@"; do
		if [[ "${arg}" == *"containers"*"env"*"relatedImages"* ]]; then
			sed 's/^/env|/' "${WORK}/csv-env"
			sed 's/^/related|/' "${WORK}/csv-related"
			exit 0
		fi
	done
	echo "ERROR: unexpected oc get csv args: $*" >&2
	exit 1
fi
if [[ "$1" == whoami ]]; then echo test-user; exit 0; fi
if [[ "$1" == get && "$2" == namespaces ]]; then exit 0; fi
# Stop the real deployment script before its first cluster mutation.
if [[ "$1" == get && "$2" == namespace ]]; then exit 71; fi
echo "ERROR: unexpected oc call: $*" >&2
exit 89
FAKEOC
	cat > "${WORK_DIR}/bin/deploy" <<'FAKEDEPLOY'
#!/usr/bin/env bash
set -euo pipefail
printf 'deploy|%s|%s|%s|%s\n' "$*" "${GATEWAY_IMAGE:-}" "${SANDBOX_IMAGE:-}" "${SUPERVISOR_IMAGE:-}" >> "${FAKE_OC_WORK_DIR}/calls"
if [[ "$1" == deploy ]]; then : > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/namespace"; fi
FAKEDEPLOY
	cat > "${WORK_DIR}/bin/phase" <<'FAKEPHASE'
#!/usr/bin/env bash
set -euo pipefail
printf 'phase|%s\n' "$*" >> "${FAKE_OC_WORK_DIR}/calls"
printf '<testsuite name="fake"><testcase classname="fake" name="%s"/></testsuite>\n' "$2" > "$3"
FAKEPHASE
	cat > "${WORK_DIR}/bin/openshell" <<'FAKECLI'
#!/usr/bin/env bash
printf 'openshell|%s\n' "$*" >> "${FAKE_OC_WORK_DIR}/calls"
FAKECLI
	cat > "${WORK_DIR}/bin/git" <<'FAKEGIT'
#!/usr/bin/env bash
printf 'git|%s\n' "$*" >> "${FAKE_OC_WORK_DIR}/calls"
echo 'no Git metadata in test image' >&2
exit 1
FAKEGIT
	cat > "${WORK_DIR}/bin/helm" <<'FAKEHELM'
#!/usr/bin/env bash
echo 'ERROR: unexpected Helm mutation' >&2
exit 89
FAKEHELM
	cat > "${WORK_DIR}/bin/sleep" <<'FAKESLEEP'
#!/usr/bin/env bash
printf 'sleep|%s\n' "$*" >> "${FAKE_OC_WORK_DIR}/calls"
FAKESLEEP
	chmod +x "${WORK_DIR}/bin/"*
	export FAKE_OC_WORK_DIR="${WORK_DIR}"
	export PATH="${WORK_DIR}/bin:${ORIG_PATH}"
	export OPENSHELL_BIN="${WORK_DIR}/bin/openshell"
	export OPENSHELL_E2E_DEPLOY_SCRIPT="${WORK_DIR}/bin/deploy"
	export OPENSHELL_E2E_PHASE_RUNNER="${WORK_DIR}/bin/phase"
}

teardown() {
	if [[ -n "${WORK_DIR}" ]]; then
		rm -rf "${WORK_DIR}"
		WORK_DIR=""
	fi
	export PATH="${ORIG_PATH}"
	unset GATEWAY_IMAGE SANDBOX_IMAGE SUPERVISOR_IMAGE 2>/dev/null || true
}

# Helpers to generate valid test images.
rhoai_gw() { echo "registry.redhat.io/rhoai/odh-openshell-gateway@sha256:$(printf '1%.0s' {1..64})"; }
rhoai_sb() { echo "registry.redhat.io/rhoai/odh-openshell-sandbox@sha256:$(printf '2%.0s' {1..64})"; }
rhoai_sv() { echo "registry.redhat.io/rhoai/odh-openshell-supervisor@sha256:$(printf '3%.0s' {1..64})"; }
odh_gw()   { echo "quay.io/opendatahub/odh-openshell-gateway@sha256:$(printf 'a%.0s' {1..64})"; }
odh_sb()   { echo "quay.io/opendatahub/odh-openshell-sandbox@sha256:$(printf 'b%.0s' {1..64})"; }
odh_sv()   { echo "quay.io/opendatahub/odh-openshell-supervisor@sha256:$(printf 'c%.0s' {1..64})"; }

setup_rhoai_csv() {
	local gw="${1:-$(rhoai_gw)}" sb="${2:-$(rhoai_sb)}" sv="${3:-$(rhoai_sv)}"
	printf '%s\n' "operator-ns|rhods-operator.3.6.0|Succeeded||" > "${WORK_DIR}/csv-list"
	printf '%s\n' \
		"RELATED_IMAGE_ODH_OPENSHELL_GATEWAY_IMAGE|${gw}" \
		"RELATED_IMAGE_ODH_OPENSHELL_SANDBOX_IMAGE|${sb}" \
		"RELATED_IMAGE_ODH_OPENSHELL_SUPERVISOR_IMAGE|${sv}" > "${WORK_DIR}/csv-env"
}

setup_odh_csv() {
	local gw="${1:-$(odh_gw)}" sb="${2:-$(odh_sb)}" sv="${3:-$(odh_sv)}"
	printf '%s\n' "operator-ns|opendatahub-operator.v3.6.0|Succeeded||" > "${WORK_DIR}/csv-list"
	printf '%s\n' \
		"RELATED_IMAGE_ODH_OPENSHELL_GATEWAY_IMAGE|${gw}" \
		"RELATED_IMAGE_ODH_OPENSHELL_SANDBOX_IMAGE|${sb}" \
		"RELATED_IMAGE_ODH_OPENSHELL_SUPERVISOR_IMAGE|${sv}" > "${WORK_DIR}/csv-env"
}

# ---------------------------------------------------------------------------
# Discovery tests
# ---------------------------------------------------------------------------
echo "=== Discovery tests ==="

test_rhoai_success() {
	setup; setup_rhoai_csv
	local output
	output="$(discover_e2e_images 2>/dev/null)"
	echo "${output}" | grep -q "^GATEWAY_IMAGE	$(rhoai_gw)$" || { teardown; return 1; }
	echo "${output}" | grep -q "^SANDBOX_IMAGE	$(rhoai_sb)$" || { teardown; return 1; }
	echo "${output}" | grep -q "^SUPERVISOR_IMAGE	$(rhoai_sv)$" || { teardown; return 1; }
	teardown
}
run_test "RHOAI CSV success" test_rhoai_success

test_odh_success() {
	setup; setup_odh_csv
	local output
	output="$(discover_e2e_images 2>/dev/null)"
	echo "${output}" | grep -q "^GATEWAY_IMAGE	$(odh_gw)$" || { teardown; return 1; }
	echo "${output}" | grep -q "^SANDBOX_IMAGE	$(odh_sb)$" || { teardown; return 1; }
	echo "${output}" | grep -q "^SUPERVISOR_IMAGE	$(odh_sv)$" || { teardown; return 1; }
	teardown
}
run_test "ODH CSV success" test_odh_success

test_no_olm_api() {
	setup
	echo "subscriptions.operators.coreos.com" > "${WORK_DIR}/api-resources"
	local output
	output="$(discover_e2e_images 2>/dev/null)" || { teardown; return 1; }
	[[ -z "${output}" ]] || { teardown; return 1; }
	teardown
}
run_test "No OLM API returns empty" test_no_olm_api

test_unrelated_operators() {
	setup
	printf '%s\n' "operator-ns|other-operator.1.0|Succeeded||" > "${WORK_DIR}/csv-list"
	local output
	output="$(discover_e2e_images 2>/dev/null)" || { teardown; return 1; }
	[[ -z "${output}" ]] || { teardown; return 1; }
	teardown
}
run_test "Unrelated operators return empty" test_unrelated_operators

test_no_installed_csvs() {
	setup
	: > "${WORK_DIR}/csv-list"
	local output
	output="$(discover_e2e_images 2>/dev/null)" || { teardown; return 1; }
	[[ -z "${output}" ]] || { teardown; return 1; }
	teardown
}
run_test "No installed CSVs return empty" test_no_installed_csvs

test_copied_csvs_ignored() {
	setup; setup_rhoai_csv
	# Add OLM copies and a replacing CSV.
	printf '%s\n' \
		"operator-ns|rhods-operator.3.6.0|Succeeded||" \
		"copied-ns|rhods-operator.3.6.0|Succeeded|operator-ns|" \
		"another-ns|rhods-operator.3.6.0|Succeeded||Copied" \
		"replacer-ns|rhods-operator.3.5.0|Replacing||" > "${WORK_DIR}/csv-list"
	local output
	output="$(discover_e2e_images 2>/dev/null)"
	local count
	count="$(echo "${output}" | grep -c "^GATEWAY_IMAGE	")"
	[[ "${count}" -eq 1 ]] || { teardown; return 1; }
	teardown
}
run_test "Copied and replacing CSVs are ignored" test_copied_csvs_ignored

test_multiple_operators_fail() {
	setup
	printf '%s\n' \
		"ns1|rhods-operator.3.6.0|Succeeded||" \
		"ns2|opendatahub-operator.3.6.0|Succeeded||" > "${WORK_DIR}/csv-list"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "Multiple Succeeded operators fail" test_multiple_operators_fail

test_no_successful_csv_fails() {
	setup
	printf '%s\n' "operator-ns|rhods-operator.3.6.0|Installing||" > "${WORK_DIR}/csv-list"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "No Succeeded CSV fails" test_no_successful_csv_fails

test_partial_override() {
	setup; setup_rhoai_csv
	export GATEWAY_IMAGE="custom.example/gateway:dev"
	local output
	output="$(discover_e2e_images 2>/dev/null)"
	echo "${output}" | grep -q "^GATEWAY_IMAGE	" && { teardown; return 1; }
	echo "${output}" | grep -q "^SANDBOX_IMAGE	" || { teardown; return 1; }
	echo "${output}" | grep -q "^SUPERVISOR_IMAGE	" || { teardown; return 1; }
	teardown
}
run_test "Partial override skips set image" test_partial_override

test_all_overrides_bypass_discovery() {
	setup
	export GATEWAY_IMAGE="custom.example/gateway:dev"
	export SANDBOX_IMAGE="custom.example/sandbox:dev"
	export SUPERVISOR_IMAGE="custom.example/supervisor:dev"
	# Broken oc that would fail if called.
	printf '%s\n' '#!/usr/bin/env bash' 'echo "oc called unexpectedly" >&2; exit 1' > "${WORK_DIR}/bin/oc"
	chmod +x "${WORK_DIR}/bin/oc"
	local output
	output="$(discover_e2e_images 2>/dev/null)" || { teardown; return 1; }
	[[ -z "${output}" ]] || { teardown; return 1; }
	teardown
}
run_test "All overrides bypass cluster queries" test_all_overrides_bypass_discovery

test_empty_override_triggers_discovery() {
	setup; setup_rhoai_csv
	export GATEWAY_IMAGE=""
	local output
	output="$(discover_e2e_images 2>/dev/null)"
	echo "${output}" | grep -q "^GATEWAY_IMAGE	" || { teardown; return 1; }
	teardown
}
run_test "Empty override triggers discovery" test_empty_override_triggers_discovery

test_missing_image_fails() {
	setup
	printf '%s\n' "operator-ns|rhods-operator.3.6.0|Succeeded||" > "${WORK_DIR}/csv-list"
	printf '%s\n' \
		"RELATED_IMAGE_ODH_OPENSHELL_SANDBOX_IMAGE|$(rhoai_sb)" \
		"RELATED_IMAGE_ODH_OPENSHELL_SUPERVISOR_IMAGE|$(rhoai_sv)" > "${WORK_DIR}/csv-env"
	: > "${WORK_DIR}/csv-related"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "Missing image value fails" test_missing_image_fails

test_conflicting_image_fails() {
	setup
	printf '%s\n' "operator-ns|rhods-operator.3.6.0|Succeeded||" > "${WORK_DIR}/csv-list"
	local gw2="registry.redhat.io/rhoai/odh-openshell-gateway@sha256:$(printf '9%.0s' {1..64})"
	printf '%s\n' \
		"RELATED_IMAGE_ODH_OPENSHELL_GATEWAY_IMAGE|$(rhoai_gw)" \
		"RELATED_IMAGE_ODH_OPENSHELL_GATEWAY_IMAGE|${gw2}" \
		"RELATED_IMAGE_ODH_OPENSHELL_SANDBOX_IMAGE|$(rhoai_sb)" \
		"RELATED_IMAGE_ODH_OPENSHELL_SUPERVISOR_IMAGE|$(rhoai_sv)" > "${WORK_DIR}/csv-env"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "Conflicting image values fail" test_conflicting_image_fails

test_identical_repeated_values_allowed() {
	setup
	printf '%s\n' "operator-ns|rhods-operator.3.6.0|Succeeded||" > "${WORK_DIR}/csv-list"
	printf '%s\n' \
		"RELATED_IMAGE_ODH_OPENSHELL_GATEWAY_IMAGE|$(rhoai_gw)" \
		"RELATED_IMAGE_ODH_OPENSHELL_GATEWAY_IMAGE|$(rhoai_gw)" \
		"RELATED_IMAGE_ODH_OPENSHELL_SANDBOX_IMAGE|$(rhoai_sb)" \
		"RELATED_IMAGE_ODH_OPENSHELL_SUPERVISOR_IMAGE|$(rhoai_sv)" > "${WORK_DIR}/csv-env"
	local output
	output="$(discover_e2e_images 2>/dev/null)"
	echo "${output}" | grep -q "^GATEWAY_IMAGE	$(rhoai_gw)$" || { teardown; return 1; }
	teardown
}
run_test "Identical repeated values are allowed" test_identical_repeated_values_allowed

test_tagged_ref_fails() {
	setup; setup_rhoai_csv "registry.redhat.io/rhoai/gateway:latest"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "Tagged (non-digest) reference fails" test_tagged_ref_fails

test_short_digest_fails() {
	setup; setup_rhoai_csv "registry.redhat.io/rhoai/gateway@sha256:123"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "Short digest fails" test_short_digest_fails

test_comma_injection_fails() {
	setup
	local injected="evil.invalid/x,gateway.image.repository=evil.invalid/x@sha256:$(printf 'a%.0s' {1..64})"
	setup_rhoai_csv "${injected}"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "Comma injection fails validation" test_comma_injection_fails

test_equals_injection_fails() {
	setup
	local injected="evil.invalid/x=y@sha256:$(printf 'a%.0s' {1..64})"
	setup_rhoai_csv "${injected}"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "Equals injection fails validation" test_equals_injection_fails

test_wrong_registry_rhoai_fails() {
	setup; setup_rhoai_csv "quay.io/evil/gateway@sha256:$(printf '1%.0s' {1..64})"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "RHOAI image from wrong registry fails" test_wrong_registry_rhoai_fails

test_wrong_registry_odh_fails() {
	setup; setup_odh_csv "registry.redhat.io/rhoai/gateway@sha256:$(printf 'a%.0s' {1..64})"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "ODH image from wrong registry fails" test_wrong_registry_odh_fails

test_relatedimages_fallback() {
	setup
	printf '%s\n' "operator-ns|rhods-operator.3.6.0|Succeeded||" > "${WORK_DIR}/csv-list"
	: > "${WORK_DIR}/csv-env"
	printf '%s\n' \
		"odh_openshell_gateway_image|$(rhoai_gw)" \
		"odh_openshell_sandbox_image|$(rhoai_sb)" \
		"odh_openshell_supervisor_image|$(rhoai_sv)" > "${WORK_DIR}/csv-related"
	local output
	output="$(discover_e2e_images 2>/dev/null)"
	echo "${output}" | grep -q "^GATEWAY_IMAGE	$(rhoai_gw)$" || { teardown; return 1; }
	echo "${output}" | grep -q "^SANDBOX_IMAGE	$(rhoai_sb)$" || { teardown; return 1; }
	echo "${output}" | grep -q "^SUPERVISOR_IMAGE	$(rhoai_sv)$" || { teardown; return 1; }
	teardown
}
run_test "relatedImages fallback works" test_relatedimages_fallback

test_relatedimages_not_used_when_env_present() {
	setup
	printf '%s\n' "operator-ns|rhods-operator.3.6.0|Succeeded||" > "${WORK_DIR}/csv-list"
	printf '%s\n' \
		"RELATED_IMAGE_ODH_OPENSHELL_GATEWAY_IMAGE|$(rhoai_gw)" \
		"RELATED_IMAGE_ODH_OPENSHELL_SANDBOX_IMAGE|$(rhoai_sb)" \
		"RELATED_IMAGE_ODH_OPENSHELL_SUPERVISOR_IMAGE|$(rhoai_sv)" > "${WORK_DIR}/csv-env"
	local gw_ri="registry.redhat.io/rhoai/odh-openshell-gateway-ri@sha256:$(printf 'f%.0s' {1..64})"
	printf '%s\n' "odh_openshell_gateway_image|${gw_ri}" > "${WORK_DIR}/csv-related"
	local output
	output="$(discover_e2e_images 2>/dev/null)"
	echo "${output}" | grep -q "^GATEWAY_IMAGE	$(rhoai_gw)$" || { teardown; return 1; }
	teardown
}
run_test "relatedImages not used when env var present" test_relatedimages_not_used_when_env_present

test_oc_error_fails_closed() {
	setup
	printf '%s\n' '#!/usr/bin/env bash' 'echo "Forbidden" >&2; exit 1' > "${WORK_DIR}/bin/oc"
	chmod +x "${WORK_DIR}/bin/oc"
	discover_e2e_images 2>/dev/null && { teardown; return 1; }
	teardown; return 0
}
run_test "oc error fails closed" test_oc_error_fails_closed

configure_error() {
	printf '%s\n' "$1" > "${WORK_DIR}/error-stage"
	printf '%s\n' "$2" > "${WORK_DIR}/error-message"
	printf '%s\n' "$3" > "${WORK_DIR}/failures"
}

assert_count() {
	local expected="$1" pattern="$2" actual
	actual="$(grep -c "${pattern}" "${WORK_DIR}/calls" || true)"
	if [[ "${actual}" != "${expected}" ]]; then
		echo "Expected ${expected} calls matching ${pattern}, got ${actual}" >&2
		cat "${WORK_DIR}/calls" >&2
		return 1
	fi
}

test_query_error_fails_closed() {
	local stage="$1" message="${2:-Forbidden}"
	setup; setup_rhoai_csv
	configure_error "${stage}" "${message}" 99
	local output
	if output="$(discover_e2e_images 2>"${WORK_DIR}/stderr")"; then return 1; fi
	[[ -z "${output}" ]]
	grep -Fq "${message}" "${WORK_DIR}/stderr"
	[[ "$(cat "${WORK_DIR}/count-${stage}")" == 1 ]]
	assert_count 0 '^sleep|'
}
run_test "API authorization error is not retried" test_query_error_fails_closed api
run_test "CSV listing authorization error fails closed" test_query_error_fails_closed list
run_test "Selected CSV authorization error fails closed" test_query_error_fails_closed images
run_test "Unauthorized errors are not retried" test_query_error_fails_closed list Unauthorized
run_test "Unknown query errors fail immediately" test_query_error_fails_closed list 'unexpected error'

test_transient_retry() {
	local stage="$1" message="$2"
	setup; setup_rhoai_csv
	configure_error "${stage}" "${message}" 2
	local output
	output="$(discover_e2e_images 2>"${WORK_DIR}/stderr")"
	[[ "$(cat "${WORK_DIR}/count-${stage}")" == 3 ]]
	[[ "$(grep '^sleep|' "${WORK_DIR}/calls")" == $'sleep|1\nsleep|2' ]]
	[[ "${output}" == "$(printf 'GATEWAY_IMAGE\t%s\nSANDBOX_IMAGE\t%s\nSUPERVISOR_IMAGE\t%s' "$(rhoai_gw)" "$(rhoai_sb)" "$(rhoai_sv)")" ]]
}
run_test "API timeouts retry with backoff" test_transient_retry api 'request timeout'
run_test "CSV listing throttling retries with backoff" test_transient_retry list 'TooManyRequests (429)'
run_test "Selected CSV connection resets retry with backoff" test_transient_retry images 'connection reset by peer'

test_retry_exhaustion() {
	setup; setup_rhoai_csv
	configure_error list 'ServiceUnavailable' 99
	local output
	if output="$(discover_e2e_images 2>"${WORK_DIR}/stderr")"; then return 1; fi
	[[ -z "${output}" ]]
	[[ "$(cat "${WORK_DIR}/count-list")" == 3 ]]
	assert_count 2 '^sleep|'
}
run_test "Transient outages fail after three attempts" test_retry_exhaustion

test_no_partial_output() {
	setup; setup_rhoai_csv "$(rhoai_gw)" 'registry.redhat.io/rhoai/sandbox:latest'
	local output
	if output="$(discover_e2e_images 2>"${WORK_DIR}/stderr")"; then return 1; fi
	[[ -z "${output}" ]]
	grep -Fq SANDBOX_IMAGE "${WORK_DIR}/stderr"
}
run_test "Validation failure emits no partial image assignments" test_no_partial_output

test_missing_oc() {
	setup
	mv "${WORK_DIR}/bin/oc" "${WORK_DIR}/bin/oc-unavailable"
	local output
	if output="$(PATH="${WORK_DIR}/bin" discover_e2e_images 2>"${WORK_DIR}/stderr")"; then return 1; fi
	[[ -z "${output}" ]]
	grep -Fq 'oc is required' "${WORK_DIR}/stderr"
}
run_test "Missing oc names the required tool" test_missing_oc

test_relatedimages_conflict() {
	setup; setup_rhoai_csv
	: > "${WORK_DIR}/csv-env"
	printf 'odh_openshell_gateway_image|%s\nodh_openshell_gateway_image|%s\n' \
		"$(rhoai_gw)" "$(rhoai_sb)" > "${WORK_DIR}/csv-related"
	local output
	if output="$(discover_e2e_images 2>"${WORK_DIR}/stderr")"; then return 1; fi
	[[ -z "${output}" ]]
	grep -Fq conflicting "${WORK_DIR}/stderr"
}
run_test "Conflicting relatedImages fail closed" test_relatedimages_conflict

# ---------------------------------------------------------------------------
# Entrypoint and deployment contracts: invoke the real scripts with fake tools.
# ---------------------------------------------------------------------------
echo ""
echo "=== Entrypoint and deploy-contract tests ==="

run_script() {
	local expected="$1" script="$2" rc=0
	shift 2
	"${BASH}" "${script}" "$@" > "${WORK_DIR}/stdout" 2> "${WORK_DIR}/stderr" || rc=$?
	if [[ "${rc}" != "${expected}" ]]; then
		cat "${WORK_DIR}/stdout" "${WORK_DIR}/stderr" >&2
		echo "Expected exit ${expected}, got ${rc}" >&2
		return 1
	fi
}

test_images_exported_across_phases() {
	setup; setup_rhoai_csv
	export GATEWAY_IMAGE=custom.example/gateway:override
	# The overridden image need not be declared by the CSV.
	sed '/RELATED_IMAGE_ODH_OPENSHELL_GATEWAY_IMAGE/d' "${WORK_DIR}/csv-env" > "${WORK_DIR}/csv-env.tmp"
	mv "${WORK_DIR}/csv-env.tmp" "${WORK_DIR}/csv-env"
	run_script 0 "${ENTRYPOINT}" tier2
	[[ "$(cat "${WORK_DIR}/count-api")" == 1 ]]
	[[ "$(cat "${WORK_DIR}/count-list")" == 1 ]]
	[[ "$(cat "${WORK_DIR}/count-images")" == 1 ]]
	assert_count 2 '^deploy|deploy '
	assert_count 2 '^deploy|teardown '
	assert_count 2 '^phase|'
	local deployments expected
	deployments="$(grep '^deploy|deploy ' "${WORK_DIR}/calls")"
	expected="|${GATEWAY_IMAGE}|$(rhoai_sb)|$(rhoai_sv)"
	[[ "$(printf '%s\n' "${deployments}" | grep -Fc "${expected}")" == 2 ]]
	[[ -f "${OPENSHELL_E2E_RESULTS_DIR}/e2e-odh-tier2-xunit.xml" ]]
}
run_test "Images are resolved once and exported to both phases" test_images_exported_across_phases

test_no_deploy_skips_discovery() {
	setup
	export OPENSHELL_E2E_DEPLOY_GATEWAY=0
	run_script 0 "${ENTRYPOINT}" smoke
	assert_count 0 '^oc|'
	assert_count 0 '^deploy|'
	assert_count 1 '^phase|'
}
run_test "Deployment disabled skips all discovery and deployment" test_no_deploy_skips_discovery

test_no_deploy_rejects_multiple_phases() {
	setup
	export OPENSHELL_E2E_DEPLOY_GATEWAY=0
	run_script 2 "${ENTRYPOINT}" tier2
	grep -Fq 'only supports single-phase tiers' "${WORK_DIR}/stderr"
	[[ ! -s "${WORK_DIR}/calls" ]]
}
run_test "Deployment disabled rejects multiple gateway modes" test_no_deploy_rejects_multiple_phases

test_discovery_failure_prevents_deployment() {
	setup; setup_rhoai_csv
	configure_error "$1" Forbidden 99
	run_script 1 "${ENTRYPOINT}" smoke
	grep -Fq 'image discovery failed' "${WORK_DIR}/stderr"
	assert_count 0 '^deploy|'
	assert_count 0 '^phase|'
	assert_count 0 '^openshell|'
}
run_test "CSV listing failure stops before deployment" test_discovery_failure_prevents_deployment list
run_test "Selected CSV failure stops before deployment" test_discovery_failure_prevents_deployment images

test_invalid_image_prevents_deployment() {
	setup; setup_rhoai_csv "$(rhoai_gw)" 'registry.redhat.io/rhoai/sandbox:latest'
	run_script 1 "${ENTRYPOINT}" smoke
	grep -Fq 'image discovery failed' "${WORK_DIR}/stderr"
	assert_count 0 '^deploy|'
	assert_count 0 '^phase|'
}
run_test "Invalid discovered image stops before deployment" test_invalid_image_prevents_deployment

test_entrypoint_all_overrides() {
	setup; setup_rhoai_csv
	: > "${WORK_DIR}/csv-env"
	export GATEWAY_IMAGE="$(rhoai_gw)" SANDBOX_IMAGE="$(rhoai_sb)" SUPERVISOR_IMAGE="$(rhoai_sv)"
	run_script 0 "${ENTRYPOINT}" smoke
	assert_count 0 '^oc|'
	assert_count 1 '^deploy|deploy '
	grep -Fq "|${GATEWAY_IMAGE}|${SANDBOX_IMAGE}|${SUPERVISOR_IMAGE}" "${WORK_DIR}/calls"
}
run_test "Complete overrides bypass CSVs without runtime images" test_entrypoint_all_overrides

test_complete_images_need_no_tag() {
	setup
	if [[ "$1" == digest ]]; then
		export GATEWAY_IMAGE="$(rhoai_gw)" SANDBOX_IMAGE="$(rhoai_sb)" SUPERVISOR_IMAGE="$(rhoai_sv)"
	else
		export GATEWAY_IMAGE=example.test/gateway:dev SANDBOX_IMAGE=example.test/sandbox:dev SUPERVISOR_IMAGE=example.test/supervisor:dev
	fi
	# Exit 71 is the fake namespace query, before any deployment mutation.
	run_script 71 "${SCRIPTS_DIR}/openshell-deploy-from-quay.sh" --yes
	grep -Fq "${GATEWAY_IMAGE}" "${WORK_DIR}/stdout"
	grep -Fq "${SANDBOX_IMAGE}" "${WORK_DIR}/stdout"
	grep -Fq "${SUPERVISOR_IMAGE}" "${WORK_DIR}/stdout"
	assert_count 0 '^git|'
}
run_test "Deploy accepts digest images without IMAGE_TAG or Git" test_complete_images_need_no_tag digest
run_test "Deploy accepts tagged images without IMAGE_TAG or Git" test_complete_images_need_no_tag tagged

test_bare_repository_requires_tag() {
	setup
	export GATEWAY_IMAGE=example.test/gateway SANDBOX_IMAGE="$(rhoai_sb)" SUPERVISOR_IMAGE="$(rhoai_sv)"
	run_script 1 "${SCRIPTS_DIR}/openshell-deploy-from-quay.sh" --yes
	grep -Fq 'IMAGE_TAG is required' "${WORK_DIR}/stderr"
	assert_count 1 '^git|'
}
run_test "Deploy rejects a bare repository without IMAGE_TAG or Git" test_bare_repository_requires_tag

test_bare_repository_uses_explicit_tag() {
	setup
	export GATEWAY_IMAGE=example.test/gateway SANDBOX_IMAGE="$(rhoai_sb)" SUPERVISOR_IMAGE="$(rhoai_sv)" IMAGE_TAG=custom
	run_script 71 "${SCRIPTS_DIR}/openshell-deploy-from-quay.sh" --yes
	grep -Fq 'example.test/gateway:custom' "${WORK_DIR}/stdout"
	assert_count 0 '^git|'
}
run_test "Deploy applies IMAGE_TAG to a bare repository" test_bare_repository_uses_explicit_tag

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  Passed: ${passed}"
echo "  Failed: ${failed}"
if [[ ${#errors[@]} -gt 0 ]]; then
	echo "  Failed tests:"
	for name in "${errors[@]}"; do
		echo "    - ${name}"
	done
fi
echo ""

[[ "${failed}" -eq 0 ]]
