#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Run exactly one validated ODH tier phase.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
if [[ "${OPENSHELL_BIN:-}" == */* && "${OPENSHELL_BIN}" != /* ]]; then
	OPENSHELL_BIN="${ROOT}/${OPENSHELL_BIN}"
	export OPENSHELL_BIN
fi
if [[ -z "${OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE:-}" ]]; then
	OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE="$(oc config current-context)"
	[[ -n "${OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE}" ]] || {
		echo "ERROR: no active Kubernetes context for ODH tests" >&2
		exit 1
	}
	export OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE
fi
PYTHON_BIN="${PYTHON_BIN:-python3}"
TIER="${1:-}"
PHASE="${2:-}"
REPORT="${3:-}"
if [[ -z "${TIER}" || -z "${PHASE}" || -z "${REPORT}" || $# -ne 3 ]]; then
	echo "Usage: $0 <tier> <phase> <phase-report.xml>" >&2
	exit 2
fi

resolved="$("${PYTHON_BIN}" "${SCRIPT_DIR}/tier_plan.py" "${TIER}" "${SCRIPT_DIR}/tiers.toml" "${PHASE}")"
filter="$(printf '%s' "${resolved}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["filter"])')"
results_dir="${OPENSHELL_E2E_RESULTS_DIR:-${ROOT}/results}"
mkdir -p "${results_dir}"
results_dir="$(cd "${results_dir}" && pwd)"
export OPENSHELL_E2E_RESULTS_DIR="${results_dir}"

report_parent="$(cd "$(dirname "${REPORT}")" 2>/dev/null && pwd)" || {
	echo "ERROR: phase report parent directory does not exist" >&2
	exit 2
}
report_name="${REPORT##*/}"
if [[ "${report_parent}" != "${results_dir}" || "${report_name}" != *.xml ]]; then
	echo "ERROR: phase report must be an XML file directly inside ${results_dir}" >&2
	exit 2
fi
name="${report_name%.xml}"
report="${results_dir}/${report_name}"
if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	echo "ERROR: invalid report name: ${name}" >&2
	exit 2
fi

junit_xml="${results_dir}/e2e-odh.xml"
rm -f "${junit_xml}" "${report}" "${report%.xml}.html"
config_file="$(mktemp)"
trap 'rm -f "${config_file}"' EXIT
"${PYTHON_BIN}" - "${ROOT}/.config/nextest.toml" "${config_file}" "${junit_xml}" <<'PY'
import pathlib, sys
source, destination, report = map(pathlib.Path, sys.argv[1:])
text = source.read_text()
old = 'path = "../../../../../results/e2e-odh.xml"'
if old not in text:
    raise SystemExit("ODH nextest JUnit path setting not found")
destination.write_text(text.replace(old, f'path = "{report}"'))
PY
nextest_args=(--profile e2e-odh --config-file "${config_file}" --no-tests fail -E "${filter}")
if [[ -n "${OPENSHELL_E2E_NEXTEST_ARCHIVE:-}" ]]; then
	nextest_args+=(--archive-file "${OPENSHELL_E2E_NEXTEST_ARCHIVE}" --workspace-remap "${ROOT}/e2e/rust")
else
	nextest_args+=(--manifest-path "${ROOT}/e2e/rust/Cargo.toml" --target-dir "${ROOT}/e2e/rust/target" --features e2e-odh)
fi

echo "==> Running ODH ${TIER}/${PHASE}: ${filter}"
status=0
nextest_pid=""
stop_nextest() {
	local signal="$1" code="$2"
	trap '' INT TERM
	if [[ -n "${nextest_pid}" ]]; then
		kill -"${signal}" "${nextest_pid}" 2>/dev/null || true
		wait "${nextest_pid}" || true
	fi
	exit "${code}"
}
trap 'stop_nextest TERM 130' INT
trap 'stop_nextest TERM 143' TERM
cargo nextest run "${nextest_args[@]}" &
nextest_pid=$!
wait "${nextest_pid}" || status=$?
nextest_pid=""
trap - INT TERM
if [[ -f "${junit_xml}" ]]; then
	mv -f "${junit_xml}" "${report}"
	if command -v xsltproc >/dev/null 2>&1; then
		xsltproc --stringparam title "${name}" "${ROOT}/scripts/junit-to-html.xsl" "${report}" > "${report%.xml}.html" || echo "WARNING: failed to render HTML report" >&2
	else
		echo "WARNING: xsltproc not found; HTML report unavailable" >&2
	fi
	printf 'JUnit report: %s\n' "${report}"
else
	echo "ERROR: cargo-nextest did not write a JUnit report" >&2
	[[ "${status}" != 0 ]] || status=1
fi
exit "${status}"
