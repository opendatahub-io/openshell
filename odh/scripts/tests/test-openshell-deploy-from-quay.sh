#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Exercise image-digest plumbing without a cluster. The deploy script must
# forward each component digest to Helm, retain the corresponding immutable
# reference in its evidence, reject malformed or conflicting input before
# Helm runs, and keep Helm map separators out of --set-string values.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEPLOY="${ROOT}/odh/scripts/openshell-deploy-from-quay.sh"
WORKDIR="$(mktemp -d)"
MOCK_BIN="${WORKDIR}/bin"
HELM_LOG="${WORKDIR}/helm.log"

# Tests below set their own image overrides. Do not let caller state change
# which validation path a negative fixture exercises.
unset GATEWAY_IMAGE GATEWAY_IMAGE_DIGEST SUPERVISOR_IMAGE SUPERVISOR_IMAGE_DIGEST
unset SANDBOX_IMAGE SANDBOX_IMAGE_DIGEST WORKLOAD_IMAGE WORKLOAD_IMAGE_TAG WORKLOAD_IMAGE_DIGEST
unset IMAGE_TAG QUAY_NAMESPACE

cleanup() {
	rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${MOCK_BIN}" "${WORKDIR}/home" "${WORKDIR}/config"
: > "${HELM_LOG}"

cat > "${MOCK_BIN}/oc" <<'OC'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
joined=" ${args[*]} "
if [[ "${joined}" == *" whoami "* ]]; then
	if [[ "${joined}" == *" --show-server "* ]]; then echo https://api.example.test; else echo test-user; fi
	exit 0
fi
if [[ "${joined}" == *" api-resources "* ]]; then echo routes; exit 0; fi
if [[ "${joined}" == *" get ingresses.config/cluster "* ]]; then echo apps.example.test; exit 0; fi
if [[ "${joined}" == *" get namespace "* ]]; then exit 0; fi
if [[ "${joined}" == *" get secret openshell-client-tls "* ]]; then printf 'Y2VydA==\n'; exit 0; fi
if [[ "${joined}" == *" create namespace "* ]]; then printf 'apiVersion: v1\nkind: Namespace\n'; exit 0; fi
if [[ "${joined}" == *" label --local "* || "${joined}" == *" create -f - "* ]]; then cat; exit 0; fi
if [[ "${joined}" == *" rollout status "* || "${joined}" == *" wait "* ]]; then exit 0; fi
exit 0
OC
chmod +x "${MOCK_BIN}/oc"

cat > "${MOCK_BIN}/helm" <<'HELM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${ODH_TEST_HELM_LOG}"
if [[ "${1:-}" == get ]]; then
	printf '{"gatewayConfig":{"openshell.gateway.auth":{"allow_unauthenticated_users":false},"openshell.drivers.kubernetes":{"workspace_mode":"shared","image_pull_policy":"IfNotPresent","sandbox_runtime_image_pull_policy":"IfNotPresent","supervisor_image_pull_policy":"IfNotPresent"}}}\n'
fi
HELM
chmod +x "${MOCK_BIN}/helm"

cat > "${MOCK_BIN}/openshell" <<'OPENSH'
#!/usr/bin/env bash
exit 0
OPENSH
chmod +x "${MOCK_BIN}/openshell"

cat > "${MOCK_BIN}/base64" <<'BASE64'
#!/usr/bin/env bash
cat
BASE64
chmod +x "${MOCK_BIN}/base64"

# The deploy script probes that the Route rejects unauthenticated gRPC calls
# before registering the gateway. Answer as an mTLS-enforcing endpoint would:
# HTTP 200 with grpc-status 16 (UNAUTHENTICATED).
cat > "${MOCK_BIN}/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
dump_header=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--dump-header) dump_header="$2"; shift 2 ;;
		*) shift ;;
	esac
done
if [[ -n "${dump_header}" ]]; then
	printf 'HTTP/2 200\r\ngrpc-status: 16\r\n\r\n' > "${dump_header}"
fi
printf '200\n'
CURL
chmod +x "${MOCK_BIN}/curl"

run_deploy() {
	# Hermetic against caller state: XDG_CONFIG_HOME (the variable the deploy
	# script actually reads — its internal XDG_CONFIG_DIR defaults from the
	# caller's XDG_CONFIG_HOME) points at the temporary config, OPENSHELL_BIN
	# pins the CLI to the mock instead of an inherited real binary, and a
	# leftover OPENSHELL_E2E_DEPLOY_STATE_DIR from a live e2e session cannot
	# redirect the deploy's state handling.
	env -u ROUTE_HOST -u OPENSHELL_E2E_RUN_ID -u OPENSHELL_E2E_DEPLOY_STATE_DIR \
		PATH="${MOCK_BIN}:${PATH}" HOME="${WORKDIR}/home" \
		XDG_CONFIG_HOME="${WORKDIR}/config" ODH_TEST_HELM_LOG="${HELM_LOG}" \
		OPENSHELL_BIN="${MOCK_BIN}/openshell" \
		PYTHON_BIN="${PYTHON_BIN_REAL}" \
		IMAGE_TAG="${IMAGE_TAG:-test-tag}" NAMESPACE=openshell-digest-test RELEASE=openshell-digest-test \
		GATEWAY_NAME=openshell-digest-test \
		"${DEPLOY}" deploy --yes
}

# Resolve a real interpreter path before the mocked environment replaces
# PATH and HOME: resolver shims (mise, venvs) need the original context.
# An explicitly configured PYTHON_BIN may be a bare command name ([[ -x ]]
# checks file paths, not PATH), so invoke it and dereference any shim via
# sys.executable — the underlying binary keeps working under the mocked
# environment, matching the unset-PYTHON_BIN fallback below.
if [[ -n "${PYTHON_BIN:-}" ]]; then
	PYTHON_BIN_REAL="$("${PYTHON_BIN}" -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
else
	PYTHON_BIN_REAL="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
fi
[[ -n "${PYTHON_BIN_REAL}" && -x "${PYTHON_BIN_REAL}" ]] ||
	{ echo "FAIL: no usable python3 interpreter found for the test (PYTHON_BIN=${PYTHON_BIN:-<unset>})" >&2; exit 1; }

digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
supervisor_digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
sandbox_digest="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
workload_digest="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

echo ">> explicit digests for every component plus a pinned workload"
GATEWAY_IMAGE_DIGEST="${digest}" SUPERVISOR_IMAGE_DIGEST="${supervisor_digest}" \
	SANDBOX_IMAGE_DIGEST="${sandbox_digest}" \
	WORKLOAD_IMAGE="registry.redhat.io/ubi9/python-312" \
	WORKLOAD_IMAGE_DIGEST="${workload_digest}" run_deploy > "${WORKDIR}/output.log"
for expected in \
	"gateway.image.digest=${digest}" \
	"supervisor.image.digest=${supervisor_digest}" \
	"sandboxRuntime.image.digest=${sandbox_digest}" \
	"sandbox.image.repository=registry.redhat.io/ubi9/python-312" \
	"sandbox.image.digest=${workload_digest}" \
	"openshiftRoute.host=openshell.apps.example.test" \
	"pkiInitJob.serverDnsNames[0]=openshell.apps.example.test" \
	"values-openshift-e2e.yaml"; do
	grep -Fq -- "${expected}" "${HELM_LOG}" || {
		echo "FAIL: Helm did not receive ${expected}" >&2
		exit 1
	}
done
if grep -Fq -- 'server.auth.allowUnauthenticatedUsers=true' "${HELM_LOG}"; then
	echo "FAIL: ODH Route deployment must not promote unauthenticated callers" >&2
	exit 1
fi
if grep -Fq -- 'sandbox.image.registry=' "${HELM_LOG}"; then
	echo "FAIL: Helm received sandbox.image.registry, a value the chart ignores (repository must be registry-qualified)" >&2
	exit 1
fi
for expected in \
	"odh-openshell-gateway@${digest}" \
	"odh-openshell-supervisor@${supervisor_digest}" \
	"odh-openshell-sandbox@${sandbox_digest}" \
	"registry.redhat.io/ubi9/python-312@${workload_digest}"; do
	grep -Fq -- "${expected}" "${WORKDIR}/output.log" || {
		echo "FAIL: deployment evidence did not contain ${expected}" >&2
		exit 1
	}
done

: > "${HELM_LOG}"
echo ">> inline digests embedded in the image references"
GATEWAY_IMAGE="quay.io/opendatahub/odh-openshell-gateway@${digest}" \
	SUPERVISOR_IMAGE="quay.io/opendatahub/odh-openshell-supervisor@${supervisor_digest}" \
	SANDBOX_IMAGE="quay.io/opendatahub/odh-openshell-sandbox@${sandbox_digest}" \
	WORKLOAD_IMAGE="registry.redhat.io/ubi9/python-312@${workload_digest}" \
	run_deploy > "${WORKDIR}/inline.log"

for expected in \
	"gateway.image.repository=opendatahub/odh-openshell-gateway" \
	"gateway.image.digest=${digest}" \
	"supervisor.image.repository=opendatahub/odh-openshell-supervisor" \
	"supervisor.image.digest=${supervisor_digest}" \
	"sandboxRuntime.image.repository=opendatahub/odh-openshell-sandbox" \
	"sandboxRuntime.image.digest=${sandbox_digest}" \
	"sandbox.image.repository=registry.redhat.io/ubi9/python-312" \
	"sandbox.image.digest=${workload_digest}"; do
	grep -Fq -- "${expected}" "${HELM_LOG}" || {
		echo "FAIL: inline digest did not produce ${expected}" >&2
		exit 1
	}
done
if grep -Fq '@sha256:' "${HELM_LOG}"; then
	echo "FAIL: inline digest leaked into a Helm image repository" >&2
	exit 1
fi

: > "${HELM_LOG}"
echo ">> default deployment without a workload image reaches Helm"
GATEWAY_IMAGE_DIGEST="${digest}" SUPERVISOR_IMAGE_DIGEST="${supervisor_digest}" \
	SANDBOX_IMAGE_DIGEST="${sandbox_digest}" \
	run_deploy > "${WORKDIR}/no-workload.log"

# The default path (no WORKLOAD_IMAGE) must deploy successfully and leave the
# chart's default sandbox workload image untouched: Helm receives the three
# component references and no sandbox.image.* override at all.
for expected in \
	"gateway.image.digest=${digest}" \
	"supervisor.image.digest=${supervisor_digest}" \
	"sandboxRuntime.image.digest=${sandbox_digest}"; do
	grep -Fq -- "${expected}" "${HELM_LOG}" || {
		echo "FAIL: default deployment did not reach Helm with ${expected}" >&2
		exit 1
	}
done
if grep -Fq -- 'sandbox.image.' "${HELM_LOG}"; then
	echo "FAIL: default deployment set sandbox.image.* values without a workload image" >&2
	exit 1
fi

: > "${HELM_LOG}"
echo ">> conflicting inline and explicit digests are rejected"
set +e
GATEWAY_IMAGE="quay.io/opendatahub/odh-openshell-gateway@${digest}" \
	GATEWAY_IMAGE_DIGEST="${supervisor_digest}" run_deploy > "${WORKDIR}/conflict.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: conflicting digest inputs were accepted" >&2; exit 1; }
grep -Fq 'GATEWAY_IMAGE_DIGEST conflicts with the digest already present' "${WORKDIR}/conflict.log" \
	|| { echo "FAIL: conflicting digest error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with conflicting digest inputs" >&2; exit 1; }

: > "${HELM_LOG}"
echo ">> malformed digests are rejected"
set +e
SUPERVISOR_IMAGE_DIGEST='sha256:not-a-digest' run_deploy > "${WORKDIR}/invalid.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: malformed digest was accepted" >&2; exit 1; }
grep -Fq 'SUPERVISOR_IMAGE_DIGEST must be a lowercase sha256 digest' "${WORKDIR}/invalid.log" \
	|| { echo "FAIL: malformed digest error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with malformed digest" >&2; exit 1; }

: > "${HELM_LOG}"
echo ">> image references with an empty digest are rejected"
set +e
GATEWAY_IMAGE="quay.io/opendatahub/odh-openshell-gateway@" \
	run_deploy > "${WORKDIR}/empty-digest.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: empty digest delimiter was accepted" >&2; exit 1; }
grep -Fq 'GATEWAY_IMAGE must carry a valid sha256 digest' "${WORKDIR}/empty-digest.log" \
	|| { echo "FAIL: empty digest error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with an empty digest delimiter" >&2; exit 1; }

: > "${HELM_LOG}"
echo ">> image references with an empty tag are rejected"
set +e
GATEWAY_IMAGE="quay.io/opendatahub/odh-openshell-gateway:" \
	run_deploy > "${WORKDIR}/empty-tag.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: empty tag delimiter was accepted" >&2; exit 1; }
grep -Fq 'GATEWAY_IMAGE must carry a valid image tag' "${WORKDIR}/empty-tag.log" \
	|| { echo "FAIL: empty tag error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with an empty tag delimiter" >&2; exit 1; }

: > "${HELM_LOG}"
echo ">> workload inputs without a workload image are rejected"
set +e
WORKLOAD_IMAGE_DIGEST="${workload_digest}" run_deploy > "${WORKDIR}/workload-missing.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: workload digest without image was accepted" >&2; exit 1; }
grep -Fq 'WORKLOAD_IMAGE is required when setting WORKLOAD_IMAGE_TAG or WORKLOAD_IMAGE_DIGEST' "${WORKDIR}/workload-missing.log" \
	|| { echo "FAIL: workload image requirement error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran without a workload image" >&2; exit 1; }

: > "${HELM_LOG}"
echo ">> workload tags conflicting with a complete workload reference are rejected"
set +e
WORKLOAD_IMAGE="quay.io/opendatahub/odh-openshell-workload:v1" \
	WORKLOAD_IMAGE_TAG="v2" \
	run_deploy > "${WORKDIR}/workload-tag-conflict.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: workload tag conflicting with a tagged reference was accepted" >&2; exit 1; }
grep -Fq 'WORKLOAD_IMAGE_TAG conflicts with the complete reference' "${WORKDIR}/workload-tag-conflict.log" \
	|| { echo "FAIL: workload tag conflict error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with a conflicting workload tag" >&2; exit 1; }

: > "${HELM_LOG}"
set +e
WORKLOAD_IMAGE="quay.io/opendatahub/odh-openshell-workload@${digest}" \
	WORKLOAD_IMAGE_TAG="v2" \
	run_deploy > "${WORKDIR}/workload-tag-digest-conflict.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: workload tag conflicting with a digest reference was accepted" >&2; exit 1; }
grep -Fq 'WORKLOAD_IMAGE_TAG conflicts with the complete reference' "${WORKDIR}/workload-tag-digest-conflict.log" \
	|| { echo "FAIL: workload tag over digest conflict error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with a workload tag over a digest reference" >&2; exit 1; }

: > "${HELM_LOG}"
echo ">> an explicit workload tag on a bare workload repository is honored"
WORKLOAD_IMAGE="quay.io/opendatahub/odh-openshell-workload" \
	WORKLOAD_IMAGE_TAG="v2" \
	run_deploy > "${WORKDIR}/workload-tag-bare.log" 2>&1
grep -Fq 'sandbox.image.tag=v2' "${HELM_LOG}" \
	|| { echo "FAIL: explicit workload tag did not reach Helm" >&2; exit 1; }
grep -Fq 'sandbox.image.repository=quay.io/opendatahub/odh-openshell-workload' "${HELM_LOG}" \
	|| { echo "FAIL: bare workload run did not reach Helm with the repository" >&2; exit 1; }

: > "${HELM_LOG}"
echo ">> Helm separators in image references are rejected"
set +e
WORKLOAD_IMAGE='registry.redhat.io/ubi9/python-312,server.auth.allowUnauthenticatedUsers=false' \
	run_deploy > "${WORKDIR}/workload-repository-invalid.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: workload repository with Helm separator was accepted" >&2; exit 1; }
grep -Fq 'WORKLOAD_IMAGE must be a lowercase registry/repository reference without Helm separators' \
	"${WORKDIR}/workload-repository-invalid.log" \
	|| { echo "FAIL: workload repository validation error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with an invalid workload repository" >&2; exit 1; }

: > "${HELM_LOG}"
set +e
WORKLOAD_IMAGE='registry.redhat.io/ubi9/python-312' \
	WORKLOAD_IMAGE_TAG='latest,sandbox.image.pullPolicy=Always' \
	run_deploy > "${WORKDIR}/workload-tag-invalid.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: workload tag with Helm separator was accepted" >&2; exit 1; }
grep -Fq 'WORKLOAD_IMAGE_TAG must be a valid image tag without Helm separators' \
	"${WORKDIR}/workload-tag-invalid.log" \
	|| { echo "FAIL: workload tag validation error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with an invalid workload tag" >&2; exit 1; }

: > "${HELM_LOG}"
set +e
GATEWAY_IMAGE='quay.io/opendatahub/odh-openshell-gateway,server.auth.allowUnauthenticatedUsers=false' \
	run_deploy > "${WORKDIR}/gateway-repository-invalid.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: gateway repository with Helm separator was accepted" >&2; exit 1; }
grep -Fq 'GATEWAY_IMAGE must be a lowercase registry/repository reference without Helm separators' \
	"${WORKDIR}/gateway-repository-invalid.log" \
	|| { echo "FAIL: gateway repository validation error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with an invalid gateway repository" >&2; exit 1; }

: > "${HELM_LOG}"
set +e
IMAGE_TAG='test-tag,server.auth.allowUnauthenticatedUsers=true' \
	run_deploy > "${WORKDIR}/image-tag-invalid.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: image tag with Helm separator was accepted" >&2; exit 1; }
grep -Fq 'GATEWAY_IMAGE must carry a valid image tag without Helm separators' \
	"${WORKDIR}/image-tag-invalid.log" \
	|| { echo "FAIL: image tag validation error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with an invalid image tag" >&2; exit 1; }

: > "${HELM_LOG}"
echo ">> uppercase image repositories are rejected"
set +e
GATEWAY_IMAGE='quay.io/opendatahub/ODH-Openshell-Gateway' \
	run_deploy > "${WORKDIR}/gateway-uppercase.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: gateway repository with uppercase letters was accepted" >&2; exit 1; }
grep -Fq 'GATEWAY_IMAGE must be a lowercase registry/repository reference without Helm separators' \
	"${WORKDIR}/gateway-uppercase.log" \
	|| { echo "FAIL: gateway uppercase validation error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with an uppercase gateway repository" >&2; exit 1; }

: > "${HELM_LOG}"
echo ">> inline tag plus digest references are preserved"
GATEWAY_IMAGE="quay.io/opendatahub/odh-openshell-gateway:odh-stable@${digest}" \
	SUPERVISOR_IMAGE="quay.io/opendatahub/odh-openshell-supervisor@${supervisor_digest}" \
	SANDBOX_IMAGE="quay.io/opendatahub/odh-openshell-sandbox@${sandbox_digest}" \
	run_deploy > "${WORKDIR}/tag-plus-digest.log" 2>&1

# A reference carrying both a tag and a digest is valid: the tag is
# extracted from the pre-digest component, and the digest takes
# precedence when forwarded to Helm.
for expected in \
	"gateway.image.repository=opendatahub/odh-openshell-gateway" \
	"gateway.image.digest=${digest}" \
	"supervisor.image.repository=opendatahub/odh-openshell-supervisor" \
	"supervisor.image.digest=${supervisor_digest}" \
	"sandboxRuntime.image.repository=opendatahub/odh-openshell-sandbox" \
	"sandboxRuntime.image.digest=${sandbox_digest}"; do
	grep -Fq -- "${expected}" "${HELM_LOG}" || {
		echo "FAIL: tag-plus-digest reference did not produce ${expected}" >&2
		exit 1
	}
done
if grep -Fq '@sha256:' "${HELM_LOG}"; then
	echo "FAIL: inline digest leaked into a Helm image repository" >&2
	exit 1
fi

: > "${HELM_LOG}"
echo ">> inline digests with Helm separators are rejected"
set +e
GATEWAY_IMAGE="quay.io/opendatahub/odh-openshell-gateway@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,server.auth.allowUnauthenticatedUsers=true" \
	run_deploy > "${WORKDIR}/digest-separator.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: inline digest with Helm separator was accepted" >&2; exit 1; }
grep -Fq 'GATEWAY_IMAGE must carry a valid sha256 digest without Helm separators' \
	"${WORKDIR}/digest-separator.log" \
	|| { echo "FAIL: inline digest validation error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with an invalid inline digest" >&2; exit 1; }

echo "ODH deploy image-digest checks passed"
