#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Exercise the tier plan resolver's runner support: the python tier is plan
# data (no entrypoint special case), a phase may run several runners, the
# python runner may appear at most once per tier, unknown runners are
# rejected, and a python-only phase needs no nextest test selection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PLAN_RESOLVER="${ROOT}/e2e/rust/tests/odh/tier_plan.py"
TIERS_FILE="${ROOT}/e2e/rust/tests/odh/tiers.toml"

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3)}"

plan_json() {
	"${PYTHON_BIN}" "${PLAN_RESOLVER}" "$1" "${TIERS_FILE}"
}

expect_error() {
	local label="$1" tier="$2"
	if plan_json "${tier}" > /dev/null 2>&1; then
		echo "FAIL: ${label} resolved, expected a validation error" >&2
		return 1
	fi
	echo "ok: ${label} rejected"
}

echo ">> the python tier resolves from plan data with the python runner only"
python_plan="$(plan_json python)"
python_phases="$(printf '%s' "${python_plan}" | "${PYTHON_BIN}" -c '
import json, sys
plan = json.load(sys.stdin)
phases = plan["phases"]
assert len(phases) == 1, "expected 1 phase, got %d" % len(phases)
phase = phases[0]
assert phase["mode"] == "shared", phase["mode"]
assert phase["runners"] == ["python"], phase["runners"]
print("ok")
')"
printf '%s\n' "${python_phases}"

echo ">> tier2's shared phase runs nextest and the python ride-along as data"
tier2_plan="$(plan_json tier2)"
printf '%s' "${tier2_plan}" | "${PYTHON_BIN}" -c '
import json, sys
plan = json.load(sys.stdin)
shared = next(p for p in plan["phases"] if p["name"] == "shared")
assert shared["runners"] == ["nextest", "python"], shared["runners"]
managed = next(p for p in plan["phases"] if p["name"] == "managed")
assert managed["runners"] == ["nextest"], managed["runners"]
print("ok")
'

echo ">> tiers without a runners key default to nextest only"
printf '%s' "$(plan_json smoke)" | "${PYTHON_BIN}" -c '
import json, sys
plan = json.load(sys.stdin)
assert all(p["runners"] == ["nextest"] for p in plan["phases"])
print("ok")
'

echo ">> every declared tier still resolves"
while IFS= read -r tier; do
	plan_json "${tier}" > /dev/null || {
		echo "FAIL: tier ${tier} stopped resolving" >&2
		exit 1
	}
done < <("${PYTHON_BIN}" -c '
import tomllib
with open("'"${TIERS_FILE}"'", "rb") as stream:
    raw = tomllib.load(stream)
for key in raw:
    if key not in {"modes", "global_test_exclusions"}:
        print(key)
')
echo "ok: all tiers resolve"

echo ">> validation: unknown runner, duplicate python runner, python-only without selection"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

sed 's/^runners = \["python"\]$/runners = ["pythn"]/' "${TIERS_FILE}" > "${WORKDIR}/bad-runner.toml"
if "${PYTHON_BIN}" "${PLAN_RESOLVER}" python "${WORKDIR}/bad-runner.toml" > /dev/null 2>&1; then
	echo "FAIL: unknown runner accepted" >&2
	exit 1
fi
echo "ok: unknown runner rejected"

cp "${TIERS_FILE}" "${WORKDIR}/dup-python.toml"
printf '\n[python.managed]\ndescription = "second python phase"\nrunners = ["python"]\n' >> "${WORKDIR}/dup-python.toml"
if duplicate_error="$("${PYTHON_BIN}" "${PLAN_RESOLVER}" python "${WORKDIR}/dup-python.toml" 2>&1)"; then
	echo "FAIL: python runner accepted in two phases" >&2
	exit 1
fi
if [[ "${duplicate_error}" != *"at most one phase"* ]]; then
	echo "FAIL: expected duplicate-python validation, got: ${duplicate_error}" >&2
	exit 1
fi
echo "ok: python runner limited to one phase per tier"

cp "${TIERS_FILE}" "${WORKDIR}/python-rust-selection.toml"
sed_in_place() {
	if sed --version > /dev/null 2>&1; then
		sed -i "$@"
	else
		sed -i '' "$@"
	fi
}
sed_in_place '/^runners = \["python"\]$/a\
upstream_tests = ["workspace_lifecycle"]' "${WORKDIR}/python-rust-selection.toml"
if selection_error="$("${PYTHON_BIN}" "${PLAN_RESOLVER}" python "${WORKDIR}/python-rust-selection.toml" 2>&1)"; then
	echo "FAIL: python-only phase accepted a nextest selection" >&2
	exit 1
fi
if [[ "${selection_error}" != *"runners omit nextest"* ]]; then
	echo "FAIL: expected python/nextest selection validation, got: ${selection_error}" >&2
	exit 1
fi
echo "ok: python-only phase rejects a nextest selection"

sed 's/^runners = \["python"\]$/runners = ["python", "python"]/' "${TIERS_FILE}" > "${WORKDIR}/same-phase-duplicate.toml"
if duplicate_phase_error="$("${PYTHON_BIN}" "${PLAN_RESOLVER}" python "${WORKDIR}/same-phase-duplicate.toml" 2>&1)"; then
	echo "FAIL: duplicate runner within one phase accepted" >&2
	exit 1
fi
if [[ "${duplicate_phase_error}" != *"duplicate runner"* ]]; then
	echo "FAIL: expected same-phase duplicate validation, got: ${duplicate_phase_error}" >&2
	exit 1
fi
echo "ok: duplicate runner within one phase rejected"

echo "tier plan runner checks passed"
