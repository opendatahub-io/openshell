#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Exercise the public ODH image entrypoint contract without a cluster. The
# temporary layout supplies stubs for deploy, Rust, Python, and CLI commands
# so this test verifies dispatch and lifecycle ordering rather than their
# individual implementations.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKDIR="$(mktemp -d)"
FIXTURE="${WORKDIR}/fixture"
LOG="${WORKDIR}/events.log"
failures=0

cleanup() {
	rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p \
	"${FIXTURE}/odh/scripts" \
	"${FIXTURE}/e2e/rust/tests/odh" \
	"${FIXTURE}/providers" \
	"${FIXTURE}/bin" \
	"${FIXTURE}/.kube"
cp "${ROOT}/odh/scripts/e2e-odh-entrypoint.sh" "${FIXTURE}/odh/scripts/e2e-odh-entrypoint.sh"
chmod +x "${FIXTURE}/odh/scripts/e2e-odh-entrypoint.sh"
printf 'fixture kubeconfig\n' > "${FIXTURE}/.kube/config"

cat > "${FIXTURE}/odh/scripts/openshell-deploy-from-quay.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'deploy %s\n' "$*" >> "${ODH_ENTRYPOINT_LOG}"
if [[ "$1" == deploy ]]; then
	printf '%s\n' "${OPENSHELL_E2E_DEPLOY_STATE_DIR}" > "${ODH_ENTRYPOINT_DEPLOY_STATE_FILE}"
	mkdir -p "${OPENSHELL_E2E_DEPLOY_STATE_DIR}"
	printf 'fixture-namespace\n' > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/namespace"
	printf 'fixture-gateway\n' > "${OPENSHELL_E2E_DEPLOY_STATE_DIR}/gateway"
fi
SCRIPT
cat > "${FIXTURE}/odh/scripts/run-odh-python-tests.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'python %s\n' "$*" >> "${ODH_ENTRYPOINT_LOG}"
SCRIPT
cat > "${FIXTURE}/e2e/rust/tests/odh/run-odh-test-tier.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'rust %s\n' "$*" >> "${ODH_ENTRYPOINT_LOG}"
SCRIPT
cat > "${FIXTURE}/bin/openshell" <<'SCRIPT'
#!/usr/bin/env bash
printf 'openshell %s\n' "$*" >> "${ODH_ENTRYPOINT_LOG}"
SCRIPT
chmod +x \
	"${FIXTURE}/odh/scripts/openshell-deploy-from-quay.sh" \
	"${FIXTURE}/odh/scripts/run-odh-python-tests.sh" \
	"${FIXTURE}/e2e/rust/tests/odh/run-odh-test-tier.sh" \
	"${FIXTURE}/bin/openshell"

fail() {
	echo "FAIL: $*" >&2
	failures=$((failures + 1))
}

run_entrypoint() {
	: > "${LOG}"
	ODH_ENTRYPOINT_LOG="${LOG}" \
	ODH_ENTRYPOINT_DEPLOY_STATE_FILE="${WORKDIR}/state-dir" \
	PATH="${FIXTURE}/bin:${PATH}" \
	"${FIXTURE}/odh/scripts/e2e-odh-entrypoint.sh" "$@"
}

# SDK must not require a kubeconfig or call the deploy lifecycle.
run_entrypoint sdk
grep -qx 'python sdk' "${LOG}" || fail "sdk must dispatch to the Python runner"
[[ "$(wc -l < "${LOG}")" -eq 1 ]] || fail "sdk must not deploy or import profiles"

# gateway-e2e must use the standard lifecycle, including profile import.
run_entrypoint gateway-e2e
grep -qx 'deploy deploy --yes' "${LOG}" || fail "gateway-e2e must deploy"
grep -qx 'openshell provider profile import --from .*/providers --global' "${LOG}" \
	|| fail "gateway-e2e must import provider profiles"
grep -qx 'python gateway-e2e' "${LOG}" || fail "gateway-e2e must dispatch to Python"
grep -qx 'deploy teardown --yes' "${LOG}" || fail "gateway-e2e must tear down"

# Existing Rust modes retain the same lifecycle and tier dispatch.
run_entrypoint odh
grep -qx 'rust odh' "${LOG}" || fail "odh must dispatch to the Rust tier runner"
grep -qx 'deploy teardown --yes' "${LOG}" || fail "odh must tear down"

if [[ "${failures}" != 0 ]]; then
	echo "${failures} ODH entrypoint check(s) failed" >&2
	exit 1
fi
echo "ODH entrypoint checks passed"
