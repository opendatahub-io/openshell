#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Image-only archive execution. The upstream wrapper owns gateway deployment,
# authentication and RuntimeClass cleanup; upstream source runners stay unchanged.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-}"
case "${MODE}:$#" in
  :0 | --check:1 | --run-tests:2) ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

: "${OPENSHELL_E2E_KUBERNETES_ARCHIVE:?prebuilt Kubernetes archive required}"
: "${OPENSHELL_E2E_CONFORMANCE_ARCHIVE:?prebuilt conformance archive required}"
: "${OPENSHELL_BIN:?prebuilt openshell CLI required}"
if [[ ! -x "${OPENSHELL_BIN}" ]]; then
  echo "ERROR: openshell CLI is not executable: ${OPENSHELL_BIN}" >&2
  exit 2
fi
OPENSHELL_BIN="$(cd "$(dirname "${OPENSHELL_BIN}")" && pwd)/$(basename "${OPENSHELL_BIN}")"
export OPENSHELL_BIN
if [[ "${OPENSHELL_E2E_KUBE_BUILD_IMAGES:-0}" != 0 ]]; then
  echo "ERROR: kubernetes image mode requires OPENSHELL_E2E_KUBE_BUILD_IMAGES=0" >&2
  exit 2
fi
if [[ "${OPENSHELL_E2E_CREDENTIAL_DRIVERS:-0}" != 0 ]]; then
  echo "ERROR: kubernetes image mode supports one credential driver per invocation" >&2
  exit 2
fi
export OPENSHELL_E2E_KUBE_BUILD_IMAGES=0
export OPENSHELL_E2E_KUBERNETES_FEATURES="${OPENSHELL_E2E_KUBERNETES_FEATURES:-e2e,e2e-kubernetes}"

RESULTS_DIR="${OPENSHELL_E2E_RESULTS_DIR:-${ROOT}/results}"
REPORT_NAME="${OPENSHELL_E2E_REPORT_NAME:-e2e-kubernetes}"
if [[ ! "${REPORT_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ERROR: invalid Kubernetes report name: ${REPORT_NAME}" >&2
  exit 2
fi
mkdir -p "${RESULTS_DIR}"
RESULTS_DIR="$(cd "${RESULTS_DIR}" && pwd)"
export OPENSHELL_E2E_RESULTS_DIR="${RESULTS_DIR}"
JUNIT_XML="${RESULTS_DIR}/${REPORT_NAME}.xml"
CONFORMANCE_XML="${RESULTS_DIR}/${REPORT_NAME}-conformance.xml"
CONFIG_FILE=""
CHILD_PID=""

render_reports() {
  local report
  for report in "${JUNIT_XML}" "${CONFORMANCE_XML}"; do
    [[ -f "${report}" ]] || continue
    if ! command -v xsltproc >/dev/null 2>&1; then
      echo "WARNING: xsltproc not found; keeping JUnit reports only" >&2
      return 0
    fi
    xsltproc --stringparam title "$(basename "${report%.xml}")" \
      "${ROOT}/scripts/junit-to-html.xsl" "${report}" >"${report%.xml}.html" \
      && echo "HTML report: ${report%.xml}.html" \
      || echo "WARNING: failed to render HTML report from ${report}" >&2
  done
}

cleanup() {
  local status=$?
  trap - EXIT
  trap '' INT TERM
  if [[ -z "${MODE}" ]]; then render_reports; fi
  if [[ "${MODE}" != --run-tests && -n "${CONFIG_FILE}" ]]; then rm -f "${CONFIG_FILE}"; fi
  exit "${status}"
}

stop_child() {
  local status=$1
  trap '' INT TERM
  if [[ -n "${CHILD_PID}" ]]; then
    kill -TERM "${CHILD_PID}" 2>/dev/null || true
    wait "${CHILD_PID}" || true
  fi
  exit "${status}"
}

run_child() {
  local status=0
  "$@" &
  CHILD_PID=$!
  wait "${CHILD_PID}" || status=$?
  CHILD_PID=""
  return "${status}"
}
trap cleanup EXIT
trap 'stop_child 130' INT
trap 'stop_child 143' TERM

if [[ -z "${MODE}" ]]; then
  rm -f "${JUNIT_XML}" "${JUNIT_XML%.xml}.html" "${CONFORMANCE_XML}" "${CONFORMANCE_XML%.xml}.html"
fi
test_filter=()
if [[ -n "${OPENSHELL_E2E_KUBE_TEST:-}" ]]; then
  if [[ ! "${OPENSHELL_E2E_KUBE_TEST}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: invalid Kubernetes test binary name" >&2
    exit 2
  fi
  test_filter+=(-E "binary(=${OPENSHELL_E2E_KUBE_TEST})")
fi

run_archive() {
  local archive=$1 workspace=$2 profile=$3 report=$4 status=0
  shift 4
  run_child cargo nextest run --archive-file "${archive}" --workspace-remap "${workspace}" \
    --config-file "${CONFIG_FILE}" --profile "${profile}" --no-tests fail "$@" || status=$?
  if [[ "${status}" == 0 && ! -f "${report}" ]]; then
    echo "ERROR: ${profile} tests did not write a JUnit report" >&2
    return 1
  fi
  return "${status}"
}

if [[ "${MODE}" == --run-tests ]]; then
  CONFIG_FILE=$2
  run_archive "${OPENSHELL_E2E_CONFORMANCE_ARCHIVE}" "${ROOT}/tests/suites/conformance" \
    odh-image-conformance "${CONFORMANCE_XML}" --test-threads 1
  run_archive "${OPENSHELL_E2E_KUBERNETES_ARCHIVE}" "${ROOT}/e2e/rust" \
    e2e-kubernetes "${JUNIT_XML}" "${test_filter[@]}"
  exit 0
fi

CONFIG_FILE="$(mktemp)"
"${PYTHON_BIN:-python3}" "${ROOT}/odh/scripts/test-archive.py" config \
  "${ROOT}/.config/nextest.toml" "${CONFIG_FILE}" "${JUNIT_XML}"
for suite in kubernetes conformance; do
  archive="${OPENSHELL_E2E_KUBERNETES_ARCHIVE}"
  features="${OPENSHELL_E2E_KUBERNETES_FEATURES}"
  workspace="${ROOT}/e2e/rust"
  profile=e2e-kubernetes
  if [[ "${suite}" == conformance ]]; then
    archive="${OPENSHELL_E2E_CONFORMANCE_ARCHIVE}"
    features=""
    workspace="${ROOT}/tests/suites/conformance"
    profile=odh-image-conformance
  fi
  "${PYTHON_BIN:-python3}" "${ROOT}/odh/scripts/test-archive.py" validate "${archive}" "${suite}" "${features}"
  run_child cargo nextest list --archive-file "${archive}" --workspace-remap "${workspace}" \
    --config-file "${CONFIG_FILE}" --profile "${profile}" >/dev/null
done
if [[ "${MODE}" == --check ]]; then
  test -w "${HOME}"
  test -w "${RESULTS_DIR}"
  curl --version | grep -q 'Features:.*HTTP2'
  exit 0
fi

: "${KUBECONFIG:?kubernetes image mode requires KUBECONFIG}"
OPENSHELL_E2E_KUBE_CONTEXT="${OPENSHELL_E2E_KUBE_CONTEXT:-$(kubectl config current-context)}"
: "${OPENSHELL_E2E_KUBE_CONTEXT:?existing cluster context required}"
export OPENSHELL_E2E_KUBE_CONTEXT
run_child bash "${ROOT}/e2e/with-kube-gateway.sh" \
  bash "${ROOT}/odh/scripts/kubernetes-image.sh" --run-tests "${CONFIG_FILE}"
