#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Exercise the Python lane of the public ODH image entrypoint without a cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKDIR="$(mktemp -d)"
FIXTURE="${WORKDIR}/fixture"
LOG="${WORKDIR}/events.log"
RESULTS="${WORKDIR}/results"

cleanup() {
	rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${FIXTURE}/odh/scripts" "${FIXTURE}/providers" "${FIXTURE}/bin" "${FIXTURE}/.kube" "${FIXTURE}/.venv/bin" "${FIXTURE}/scripts" "${RESULTS}"
cp "${ROOT}/odh/scripts/e2e-odh-entrypoint.sh" "${FIXTURE}/odh/scripts/e2e-odh-entrypoint.sh"
cp "${ROOT}/odh/python-gates.toml" "${FIXTURE}/odh/python-gates.toml"
cp "${ROOT}/scripts/junit-to-html.xsl" "${FIXTURE}/scripts/junit-to-html.xsl"
chmod +x "${FIXTURE}/odh/scripts/e2e-odh-entrypoint.sh"
printf 'fixture kubeconfig\n' > "${FIXTURE}/.kube/config"

cat > "${FIXTURE}/odh/scripts/openshell-deploy-from-quay.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'deploy %s\n' "$*" >> "${ODH_ENTRYPOINT_LOG}"
if [[ "$1" == deploy ]]; then
	mkdir -p "${OPENSHELL_E2E_DEPLOY_STATE_DIR}"
	printf 'fixture-namespace\n' > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/namespace"
	printf 'fixture-gateway\n' > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/gateway"
fi
SCRIPT
cat > "${FIXTURE}/odh/scripts/merge-reports.py" <<'SCRIPT'
#!/usr/bin/env python3
import os
import pathlib
import sys

path = pathlib.Path(os.environ["OPENSHELL_E2E_RESULTS_DIR"]) / "e2e-odh-python.xml"
path.write_text("<?xml version='1.0'?><testsuites tests='1'/>\n")
print(f"JUnit report: {path}")
SCRIPT
cat > "${FIXTURE}/bin/openshell" <<'SCRIPT'
#!/usr/bin/env bash
printf 'openshell %s\n' "$*" >> "${ODH_ENTRYPOINT_LOG}"
SCRIPT
cat > "${FIXTURE}/bin/python" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'python %s\n' "$*" >> "${ODH_ENTRYPOINT_LOG}"
if [[ "$1" == *merge-reports.py ]]; then
	printf "<?xml version='1.0'?><testsuites tests='1'/>\n" > "${OPENSHELL_E2E_RESULTS_DIR}/e2e-odh-python.xml"
	exit 0
fi
if [[ "$1" == -m && "$2" == pytest ]]; then
	printf 'pytest-oidc=%s\n' "${OPENSHELL_E2E_OIDC:-}" >> "${ODH_ENTRYPOINT_LOG}"
fi
for arg in "$@"; do
	if [[ "${arg}" == --junitxml ]]; then
		# The next argument is the report path.
		write_report=1
	elif [[ "${write_report:-0}" == 1 ]]; then
		printf "<?xml version='1.0'?><testsuites tests='1'/>\n" > "${arg}"
		break
	fi
done
SCRIPT
chmod +x "${FIXTURE}/odh/scripts/openshell-deploy-from-quay.sh" "${FIXTURE}/odh/scripts/merge-reports.py" "${FIXTURE}/bin/openshell" "${FIXTURE}/bin/python"
cp "${FIXTURE}/bin/python" "${FIXTURE}/.venv/bin/python"

(
	cd "${WORKDIR}"
	ODH_ENTRYPOINT_LOG="${LOG}" \
	PATH="${FIXTURE}/bin:${PATH}" \
	PYTHON_BIN="${FIXTURE}/bin/python" \
	OPENSHELL_E2E_PYTHON="fixture/bin/python" \
	OPENSHELL_E2E_DEPLOY_SCRIPT="${FIXTURE}/odh/scripts/openshell-deploy-from-quay.sh" \
	OPENSHELL_E2E_REPORT_MERGER="${FIXTURE}/odh/scripts/merge-reports.py" \
	OPENSHELL_E2E_RESULTS_DIR="${RESULTS}" \
	OPENSHELL_E2E_RUN_ID="fixture-python" \
	OPENSHELL_BIN="${FIXTURE}/bin/openshell" \
	KUBECONFIG="${FIXTURE}/.kube/config" \
	OPENSHELL_E2E_OIDC=1 \
	"${FIXTURE}/odh/scripts/e2e-odh-entrypoint.sh" python
)

# An explicit interpreter remains relative to the caller, but uv's relative
# project environment is relative to the workspace root.
(
	cd "${WORKDIR}"
	ODH_ENTRYPOINT_LOG="${LOG}" \
	PATH="${FIXTURE}/bin:${PATH}" \
	PYTHON_BIN="${FIXTURE}/bin/python" \
	UV_PROJECT_ENVIRONMENT=".venv" \
	OPENSHELL_E2E_DEPLOY_SCRIPT="${FIXTURE}/odh/scripts/openshell-deploy-from-quay.sh" \
	OPENSHELL_E2E_REPORT_MERGER="${FIXTURE}/odh/scripts/merge-reports.py" \
	OPENSHELL_E2E_RESULTS_DIR="${RESULTS}" \
	OPENSHELL_E2E_RUN_ID="fixture-uv" \
	OPENSHELL_BIN="${FIXTURE}/bin/openshell" \
	KUBECONFIG="${FIXTURE}/.kube/config" \
	OPENSHELL_E2E_OIDC=1 \
	"${FIXTURE}/odh/scripts/e2e-odh-entrypoint.sh" python
)

grep -qx 'deploy deploy --yes --mode shared' "${LOG}"
grep -qx 'openshell provider profile import --from .*/providers --global' "${LOG}"
grep -q '^python -m pytest ' "${LOG}"
test "$(grep -cx 'pytest-oidc=0' "${LOG}")" -eq 4
test "$(grep -cx 'deploy teardown --yes --mode shared' "${LOG}")" -eq 2
test -f "${RESULTS}/e2e-odh-python.xml"
test -f "${RESULTS}/e2e-odh-python.html"

echo "ODH Python entrypoint checks passed"
