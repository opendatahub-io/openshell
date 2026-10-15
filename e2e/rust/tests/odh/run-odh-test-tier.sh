#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Run one ODH test tier against an already deployed gateway. The image
# entrypoint handles gateway setup and teardown; this script only runs tests
# and writes a JUnit XML report with an HTML companion.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TIERS_FILE="${SCRIPT_DIR}/tiers.toml"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TIER="${1:-}"

if [[ -z "${TIER}" || $# -ne 1 ]]; then
	echo "Usage: $0 <smoke|tier1|tier2|tier3|odh|full>" >&2
	exit 2
fi

# Build one nextest filter for the selected tier. Running every selected test
# in one nextest invocation gives Jenkins a complete report for the tier.
filter="$("${PYTHON_BIN}" - "${TIERS_FILE}" "${TIER}" "${SKIP_IMAGE_PROVENANCE:-0}" <<'PY'
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    tiers = tomllib.load(stream)

tier = sys.argv[2]
if tier not in tiers:
    sys.exit(f"unknown tier {tier!r}; available: {', '.join(sorted(tiers))}")

config = tiers[tier]
exclusions = config.get("upstream_test_exclusions", {})
for binary, tests in exclusions.items():
    if not re.fullmatch(r"[A-Za-z0-9_-]+", binary):
        sys.exit(f"invalid upstream test binary: {binary!r}")
    for test in tests:
        if not re.fullmatch(r"[A-Za-z0-9_:]+", test):
            sys.exit(f"invalid excluded upstream test: {test!r}")

if config.get("odh_only"):
    print("binary(=odh)")
elif config.get("all_binaries"):
    excluded = " | ".join(
        f"(binary(={binary}) & test(={test}))"
        for binary, tests in exclusions.items()
        for test in tests
    )
    print(f"(all() - ({excluded}))" if excluded else "all()")
else:
    terms = []
    odh_filter = config.get("odh_filter", "")
    if odh_filter:
        if not re.fullmatch(r"[A-Za-z0-9_:]+", odh_filter):
            sys.exit(f"invalid ODH test filter: {odh_filter!r}")
        terms.append(f"(binary(=odh) & test(~{odh_filter}))")

    provenance = "smoke::image_provenance::"
    if sys.argv[3] != "1" and not (odh_filter and provenance.startswith(odh_filter)):
        terms.append(f"(binary(=odh) & test(~{provenance}))")

    upstream_tests = config.get("upstream_tests", [])
    unknown_binaries = exclusions.keys() - set(upstream_tests)
    if unknown_binaries:
        sys.exit(f"excluded tests reference unselected binaries: {sorted(unknown_binaries)}")

    for binary in upstream_tests:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", binary):
            sys.exit(f"invalid upstream test binary: {binary!r}")
        selection = f"binary(={binary})"
        for test in exclusions.get(binary, []):
            selection = f"({selection} - test(={test}))"
        terms.append(selection)

    if not terms:
        sys.exit(f"tier {tier!r} selects no tests")
    print(" | ".join(terms))
PY
)"

name="${OPENSHELL_E2E_REPORT_NAME:-e2e-odh-${TIER}}"
if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	echo "ERROR: invalid report name: ${name}" >&2
	exit 2
fi

mkdir -p "${ROOT}/results"
junit_xml="${ROOT}/results/e2e-odh.xml"
report="${ROOT}/results/${name}.xml"
rm -f "${junit_xml}" "${report}" "${report%.xml}.html"

nextest_args=(
	--profile e2e-odh
	--config-file "${ROOT}/.config/nextest.toml"
	--no-tests fail
	-E "${filter}"
)
# The failover test is ignored by default because it deletes a gateway pod.
# Run it only after the caller has explicitly opted into destructive HA
# coverage; `all` preserves the rest of the selected tier.
if [[ "${OPENSHELL_ODH_HA_FAILOVER:-0}" == "1" ]]; then
	nextest_args+=(--run-ignored all)
fi
if [[ -n "${OPENSHELL_E2E_NEXTEST_ARCHIVE:-}" ]]; then
	nextest_args+=(
		--archive-file "${OPENSHELL_E2E_NEXTEST_ARCHIVE}"
		--workspace-remap "${ROOT}/e2e/rust"
	)
else
	nextest_args+=(
		--manifest-path "${ROOT}/e2e/rust/Cargo.toml"
		--target-dir "${ROOT}/e2e/rust/target"
		--features e2e-odh
	)
fi

echo "==> Running ODH tier ${TIER}: ${filter}"
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
	if [[ "${report}" != "${junit_xml}" ]]; then
		mv -f "${junit_xml}" "${report}"
	fi
	echo "JUnit report: ${report}"
	if command -v xsltproc >/dev/null 2>&1; then
		xsltproc --stringparam title "${name}" \
			"${ROOT}/scripts/junit-to-html.xsl" "${report}" \
			> "${report%.xml}.html" \
			|| echo "WARNING: failed to render HTML report" >&2
	else
		echo "WARNING: xsltproc not found; HTML report unavailable" >&2
	fi
else
	echo "ERROR: cargo-nextest did not write a JUnit report" >&2
	[[ "${status}" != 0 ]] || status=1
fi

exit "${status}"
