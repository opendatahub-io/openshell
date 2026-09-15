#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy a disposable upstream gateway, then run the complete SELinux ODH
# qualification suite against it. This is the CI entrypoint for RHAIENG-6877.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
FIXTURE_NAME="openshell-odh-selinux-proxy"
FIXTURE_MANIFEST="${SCRIPT_DIR}/selinux-proxy-fixture.yaml"
# Qualify the topology ODH ships. The sidecar split is not the chart default,
# and nothing in its SELinux behavior differs: the label comes from the SCC,
# and the chart sets no seLinuxOptions for either topology.
SUPERVISOR_TOPOLOGY="combined"

fail() { echo "ERROR: $*" >&2; exit 2; }

run_downstream_egress_control() {
  local fixture_host="${FIXTURE_NAME}.openshell.svc"
  local egress_policy output logs
  egress_policy="$(mktemp)"
  trap 'rm -f "${egress_policy}"' RETURN

  cat >"${egress_policy}" <<EOF
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /proc, /dev/urandom, /etc, /var/log]
  read_write: [/sandbox, /tmp, /dev/null]
landlock:
  compatibility: hard_requirement
process:
  run_as_user: sandbox
  run_as_group: sandbox
network_policies:
  selinux_proxy:
    name: selinux_proxy
    endpoints:
      - host: ${fixture_host}
        port: 8443
        tls: skip
        enforcement: enforce
        allowed_ips: ["10.0.0.0/8", "172.0.0.0/8", "192.168.0.0/16", "fc00::/7"]
    binaries:
      - path: "/**"
EOF
  if ! output="$("${OPENSHELL_BIN}" sandbox create --no-keep --policy "${egress_policy}" -- \
      python3 -c "import ssl,urllib.request; c=ssl._create_unverified_context(); print(urllib.request.urlopen('https://${fixture_host}:8443/',context=c,timeout=30).read().decode())" 2>&1)"; then
    fail "in-cluster proxy scenario failed:\n${output}"
  fi
  [[ "${output}" == *"odh-selinux-proxy-upstream"* ]] \
    || fail "approved request did not reach the in-cluster upstream:\n${output}"
  set +e
  output="$("${OPENSHELL_BIN}" sandbox create --no-keep --policy "${egress_policy}" -- \
    python3 -c "import ssl,urllib.request; urllib.request.urlopen('https://${fixture_host}:9/',context=ssl._create_unverified_context(),timeout=30)" 2>&1)"
  local denied_status=$?
  set -e
  [ "${denied_status}" -ne 0 ] && [[ "${output}" == *"403"* ]] \
    || fail "policy-denied request did not fail closed with 403:\n${output}"

  logs="$(oc --context "${OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE}" -n openshell \
    logs "deployment/${FIXTURE_NAME}" 2>&1)" \
    || fail "could not read in-cluster proxy fixture logs:\n${logs}"
  [[ "${logs}" == *"allowed"* ]] \
    || fail "approved request did not reach the proxy:\n${logs}"
  [[ "${logs}" != *"denied"* && "${logs}" != *"dial=fail"* ]] \
    || fail "proxy rejected a request it should have relayed:\n${logs}"
  [[ "${logs}" != *":9 "* && "${logs}" != *":9\n"* ]] \
    || fail "policy-denied request reached the proxy:\n${logs}"

}

run_downstream_filesystem_control() {
  local filesystem_policy output
  filesystem_policy="$(mktemp)"
  trap 'rm -f "${filesystem_policy}"' RETURN
  cat >"${filesystem_policy}" <<'EOF'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /etc, /proc, /dev]
  read_write: [/sandbox, /tmp]
landlock:
  compatibility: hard_requirement
process:
  run_as_user: sandbox
  run_as_group: sandbox
EOF
  if ! output="$("${OPENSHELL_BIN}" sandbox create --no-keep --policy "${filesystem_policy}" -- \
      sh -lc 'set -eu; test -d /dev/shm; if printf blocked >/dev/shm/openshell-landlock-denied 2>/dev/null; then exit 23; fi; test ! -e /dev/shm/openshell-landlock-denied; echo landlock-denied-ok' 2>&1)"; then
    fail "filesystem-denial scenario failed:\n${output}"
  fi
  [[ "${output}" == *"landlock-denied-ok"* ]] \
    || fail "forbidden filesystem write was not denied:\n${output}"
}

run_tests() {
  # The gateway wrapper configures the CLI context. CI normally builds the
  # matching client here; accept its standard prebuilt-binary override too.
  if [ -z "${OPENSHELL_BIN:-}" ]; then
    cargo build -p openshell-cli
    export OPENSHELL_BIN="${ROOT}/target/debug/openshell"
  fi
  "${SCRIPT_DIR}/run-selinux-enforcing.sh" --preflight
  export ODH_SELINUX_ENFORCING_VERIFIED=1
  export ODH_SELINUX_AUDIT=1
  export ODH_SELINUX_SUPERVISOR_TOPOLOGY="${SUPERVISOR_TOPOLOGY}"
  "${SCRIPT_DIR}/run-odh-test-tier.sh" smoke
  "${SCRIPT_DIR}/run-selinux-enforcing.sh" downstream-egress \
    bash "$0" __openshell_run_downstream_egress_control
  "${SCRIPT_DIR}/run-selinux-enforcing.sh" downstream-filesystem \
    bash "$0" __openshell_run_downstream_filesystem_control
  # The upstream user-namespaces test is ignored and depends on a
  # Docker-specific gateway container, so it is not an OCP qualification
  # scenario. Keep that exclusion local to this lane.
  ODH_SKIP_UPSTREAM_TESTS=user_namespaces \
    SKIP_IMAGE_PROVENANCE=1 "${SCRIPT_DIR}/run-odh-test-tier.sh" tier1
  # The upstream Kubernetes corporate-proxy test starts a proxy on the test
  # host and is intentionally a no-op unless its host fixture is enabled. A
  # remote OCP cluster cannot reach that fixture, so use the in-cluster
  # authenticated proxy control above and do not report the no-op as coverage.
  ODH_SKIP_UPSTREAM_TESTS=kubernetes_corporate_proxy \
    SKIP_IMAGE_PROVENANCE=1 "${SCRIPT_DIR}/run-odh-test-tier.sh" tier2
}

if [ "${1:-}" = "__openshell_run_odh_selinux" ]; then
  run_tests
  exit 0
fi
if [ "${1:-}" = "__openshell_run_downstream_egress_control" ]; then
  run_downstream_egress_control
  exit 0
fi
if [ "${1:-}" = "__openshell_run_downstream_filesystem_control" ]; then
  run_downstream_filesystem_control
  exit 0
fi

# This qualification lane must target an existing OpenShift cluster. The
# generic Kubernetes harness deliberately supports local k3d, which is not
# evidence of SELinux enforcement.
[ -n "${OPENSHELL_E2E_KUBE_CONTEXT:-}" ] \
  || fail "OPENSHELL_E2E_KUBE_CONTEXT is required for downstream OpenShift qualification"
command -v oc >/dev/null 2>&1 || fail "oc is required"
oc --context "${OPENSHELL_E2E_KUBE_CONTEXT}" api-resources \
  --api-group=route.openshift.io --no-headers 2>/dev/null | grep -q '^routes' \
  || fail "context ${OPENSHELL_E2E_KUBE_CONTEXT} is not an OpenShift cluster with Route support"

export ALLOWED_IMAGE_REGISTRY_PREFIXES="${ALLOWED_IMAGE_REGISTRY_PREFIXES:-ghcr.io/nvidia/openshell/,ghcr.io/nvidia/openshell-community/sandboxes/}"

SELINUX_VALUES=""
cleanup_fixture() {
  oc --context "${OPENSHELL_E2E_KUBE_CONTEXT}" -n openshell delete -f "${FIXTURE_MANIFEST}" \
    --ignore-not-found >/dev/null 2>&1 || true
  [ -z "${SELINUX_VALUES}" ] || rm -f "${SELINUX_VALUES}"
}
trap cleanup_fixture EXIT

# The sandbox routes egress through the fixture, so it must be serving before
# Helm points the gateway at it.
oc --context "${OPENSHELL_E2E_KUBE_CONTEXT}" create namespace openshell \
  --dry-run=client -o yaml | oc --context "${OPENSHELL_E2E_KUBE_CONTEXT}" apply -f -
oc --context "${OPENSHELL_E2E_KUBE_CONTEXT}" -n openshell apply -f "${FIXTURE_MANIFEST}"
oc --context "${OPENSHELL_E2E_KUBE_CONTEXT}" -n openshell rollout status \
  "deployment/${FIXTURE_NAME}" --timeout=120s

# No proxy credential: openshell-driver-kubernetes rejects credential Secrets
# under the combined topology because the workload shares the credential mount
# (see SupervisorTopology::Combined in its config validation). Authenticated
# corporate-proxy support therefore belongs to a sidecar-topology lane.
SELINUX_VALUES="$(mktemp)"
cat >"${SELINUX_VALUES}" <<EOF
supervisor:
  topology: ${SUPERVISOR_TOPOLOGY}
upstreamProxy:
  url: http://${FIXTURE_NAME}.openshell.svc:8000
EOF

VALUES="${SCRIPT_DIR}/values-selinux.yaml"
if [ -n "${OPENSHELL_E2E_KUBE_EXTRA_VALUES:-}" ]; then
  VALUES="${OPENSHELL_E2E_KUBE_EXTRA_VALUES}:${VALUES}"
fi
# Helm processes files left to right. Keep this generated qualification overlay
# last so caller-provided values cannot make the deployment's topology disagree
# with the process-label expectation in the test run.
VALUES="${VALUES}:${SELINUX_VALUES}"

OPENSHELL_E2E_KUBE_EXTRA_VALUES="${VALUES}" \
  "${ROOT}/e2e/with-kube-gateway.sh" bash "$0" __openshell_run_odh_selinux
