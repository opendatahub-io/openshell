#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# A deployment failure before the Python runner must not leave an old Python
# report to be picked up as raw evidence by a later invocation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENTRYPOINT="${SCRIPT_DIR}/../e2e-odh-entrypoint.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
RESULTS_DIR="${WORKDIR}/results"
STALE_PYTHON_REPORT="${RESULTS_DIR}/e2e-odh-python-python.xml"
MERGED_REPORT="${RESULTS_DIR}/e2e-odh-python-xunit.xml"
KUBECONFIG_FILE="${WORKDIR}/kubeconfig"
DEPLOY_SCRIPT="${WORKDIR}/fail-deploy.sh"
LOG_FILE="${WORKDIR}/entrypoint.log"

mkdir -p "${RESULTS_DIR}"
printf '<testsuites/>\n' > "${STALE_PYTHON_REPORT}"
printf '<testsuites/>\n' > "${MERGED_REPORT}"
printf 'apiVersion: v1\nkind: Config\n' > "${KUBECONFIG_FILE}"
printf '#!/usr/bin/env bash\nexit 1\n' > "${DEPLOY_SCRIPT}"
chmod +x "${DEPLOY_SCRIPT}"

if KUBECONFIG="${KUBECONFIG_FILE}" \
	OPENSHELL_E2E_RESULTS_DIR="${RESULTS_DIR}" \
	OPENSHELL_E2E_DEPLOY_SCRIPT="${DEPLOY_SCRIPT}" \
	OPENSHELL_E2E_PYTHON="${ROOT}/.venv/bin/python" \
	"${ENTRYPOINT}" python > "${LOG_FILE}" 2>&1; then
	echo "FAIL: python entrypoint unexpectedly succeeded with a failing deployment" >&2
	exit 1
fi

[[ ! -e "${STALE_PYTHON_REPORT}" ]] || {
	echo "FAIL: stale Python report survived a deployment failure" >&2
	exit 1
}
[[ ! -e "${MERGED_REPORT}" ]] || {
	echo "FAIL: stale merged report survived a deployment failure" >&2
	exit 1
}
grep -q 'deployment/preflight failed for python/shared' "${LOG_FILE}" || {
	echo "FAIL: fake deployment failure was not observed" >&2
	cat "${LOG_FILE}" >&2
	exit 1
}

echo "entrypoint clears stale Python reports before deployment"
