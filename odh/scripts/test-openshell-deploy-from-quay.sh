#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Exercise image-digest plumbing without a cluster. The deploy script must
# forward each component digest to Helm, retain the corresponding immutable
# reference in its evidence, and reject malformed input before Helm runs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY="${ROOT}/odh/scripts/openshell-deploy-from-quay.sh"
WORKDIR="$(mktemp -d)"
MOCK_BIN="${WORKDIR}/bin"
HELM_LOG="${WORKDIR}/helm.log"

# Tests below set their own workload overrides. Do not let caller state change
# which validation path a negative fixture exercises.
unset WORKLOAD_IMAGE WORKLOAD_IMAGE_TAG WORKLOAD_IMAGE_DIGEST

cleanup() {
	rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${MOCK_BIN}" "${WORKDIR}/home"
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
if [[ "${joined}" == *" rollout status "* ]]; then exit 0; fi
exit 0
OC
chmod +x "${MOCK_BIN}/oc"

cat > "${MOCK_BIN}/helm" <<'HELM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ODH_TEST_HELM_LOG}"
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

run_deploy() {
	env -u ROUTE_HOST PATH="${MOCK_BIN}:${PATH}" HOME="${WORKDIR}/home" ODH_TEST_HELM_LOG="${HELM_LOG}" \
		IMAGE_TAG="${IMAGE_TAG:-test-tag}" NAMESPACE=openshell-digest-test RELEASE=openshell-digest-test \
		GATEWAY_NAME=openshell-digest-test \
		"${DEPLOY}" deploy --yes "$@"
}

digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
supervisor_digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
sandbox_digest="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
workload_digest="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

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
	"openshiftRoute.annotations.haproxy\\.router\\.openshift\\.io/timeout=300s" \
	"openshiftRoute.annotations.haproxy\\.router\\.openshift\\.io/timeout-tunnel=300s"; do
	grep -Fq -- "${expected}" "${HELM_LOG}" || {
		echo "FAIL: Helm did not receive ${expected}" >&2
		exit 1
	}
done
if grep -Fq -- 'server.auth.allowUnauthenticatedUsers=true' "${HELM_LOG}"; then
	echo "FAIL: ODH Route deployment must not promote unauthenticated callers" >&2
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
set +e
GATEWAY_IMAGE="quay.io/opendatahub/odh-openshell-gateway@${digest}" \
	GATEWAY_IMAGE_DIGEST="${supervisor_digest}" run_deploy > "${WORKDIR}/conflict.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: conflicting digest inputs were accepted" >&2; exit 1; }
grep -Fq 'GATEWAY_IMAGE digest conflicts with GATEWAY_IMAGE_DIGEST' "${WORKDIR}/conflict.log" \
	|| { echo "FAIL: conflicting digest error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with conflicting digest inputs" >&2; exit 1; }

: > "${HELM_LOG}"
set +e
SUPERVISOR_IMAGE_DIGEST='sha256:not-a-digest' run_deploy > "${WORKDIR}/invalid.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: malformed digest was accepted" >&2; exit 1; }
grep -Fq 'SUPERVISOR_IMAGE_DIGEST must be a lowercase sha256 digest' "${WORKDIR}/invalid.log" \
	|| { echo "FAIL: malformed digest error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with malformed digest" >&2; exit 1; }

: > "${HELM_LOG}"
set +e
WORKLOAD_IMAGE_DIGEST="${workload_digest}" run_deploy > "${WORKDIR}/workload-missing.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: workload digest without image was accepted" >&2; exit 1; }
grep -Fq 'WORKLOAD_IMAGE is required when setting WORKLOAD_IMAGE_TAG or WORKLOAD_IMAGE_DIGEST' "${WORKDIR}/workload-missing.log" \
	|| { echo "FAIL: workload image requirement error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran without a workload image" >&2; exit 1; }

: > "${HELM_LOG}"
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
IMAGE_TAG='test-tag,server.auth.allowUnauthenticatedUsers=false' \
	run_deploy > "${WORKDIR}/image-tag-invalid.log" 2>&1
status=$?
set -e
[[ "${status}" != 0 ]] || { echo "FAIL: image tag with Helm separator was accepted" >&2; exit 1; }
grep -Fq 'IMAGE_TAG must be a valid image tag without Helm separators' \
	"${WORKDIR}/image-tag-invalid.log" \
	|| { echo "FAIL: image tag validation error was not clear" >&2; exit 1; }
[[ ! -s "${HELM_LOG}" ]] || { echo "FAIL: Helm ran with an invalid image tag" >&2; exit 1; }

echo "ODH deploy image-digest checks passed"
