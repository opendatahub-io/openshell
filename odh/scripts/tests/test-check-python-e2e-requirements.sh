#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Exercise check-python-e2e-requirements.py: the dev group's pytest plugins
# must be mirrored in odh/requirements.in (names and pins), an allowlisted
# exclusion is tolerated, and any drift fails with the offending entry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CHECK="${SCRIPT_DIR}/../check-python-e2e-requirements.py"

PYTHON_BIN="${PYTHON_BIN:-${ROOT}/.venv/bin/python}"
if [[ ! -x "${PYTHON_BIN}" ]]; then
	PYTHON_BIN="$(command -v python3)"
fi

echo ">> the current repository passes the mirror check"
"${PYTHON_BIN}" "${CHECK}" "${ROOT}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
mkdir -p "${WORKDIR}/odh"

reset_inputs() {
	cp "${ROOT}/pyproject.toml" "${WORKDIR}/pyproject.toml"
	cp "${ROOT}/odh/requirements.in" "${WORKDIR}/odh/requirements.in"
	cp "${ROOT}/odh/requirements.txt" "${WORKDIR}/odh/requirements.txt"
}

reset_inputs

expect_failure() {
	local label="$1"
	local expected="${2:-}"
	local output
	if output="$("${PYTHON_BIN}" "${CHECK}" "${WORKDIR}" 2>&1)"; then
		echo "FAIL: ${label} passed, expected drift failure" >&2
		return 1
	fi
	if [[ -n "${expected}" && "${output}" != *"${expected}"* ]]; then
		echo "FAIL: ${label} did not report ${expected@Q}" >&2
		echo "${output}" >&2
		return 1
	fi
	echo "ok: ${label} rejected"
}

sed_in_place() {
	if sed --version > /dev/null 2>&1; then
		sed -i "$@"
	else
		sed -i '' "$@"
	fi
}

echo ">> equivalent PEP 503 spellings do not create drift"
sed_in_place 's/pytest-xdist/pytest_xdist/' "${WORKDIR}/pyproject.toml"
if ! "${PYTHON_BIN}" "${CHECK}" "${WORKDIR}" > /dev/null 2>&1; then
	echo "FAIL: equivalent pytest package spelling was rejected" >&2
	exit 1
fi
echo "ok: equivalent package spelling accepted"
reset_inputs

echo ">> pytest requirements with extras are parsed and mirrored"
sed_in_place 's/pytest-xdist>=3.0/pytest-xdist[extra]>=3.0/' "${WORKDIR}/pyproject.toml"
sed_in_place 's/pytest-xdist>=3.0/pytest-xdist[extra]>=3.0/' "${WORKDIR}/odh/requirements.in"
if ! "${PYTHON_BIN}" "${CHECK}" "${WORKDIR}" > /dev/null 2>&1; then
	echo "FAIL: mirrored pytest requirement with extras was rejected" >&2
	exit 1
fi
echo "ok: pytest requirement with extras accepted"
reset_inputs

echo ">> invalid pytest requirement syntax cannot be ignored"
sed_in_place 's/pytest-xdist>=3.0/pytest-xdist[extra>=3.0/' "${WORKDIR}/pyproject.toml"
expect_failure "invalid pytest requirement" "invalid pytest requirement"
reset_inputs

echo ">> a dev-group plugin missing from the image is drift"
awk '
	/^    "pytest-xdist>=3.0",$/ {
		print
		print "    \"pytest-fixturecheck>=1.0\","
		next
	}
	{ print }
' "${WORKDIR}/pyproject.toml" > "${WORKDIR}/pyproject.toml.tmp"
mv "${WORKDIR}/pyproject.toml.tmp" "${WORKDIR}/pyproject.toml"
expect_failure "unmirrored new dev plugin"
reset_inputs

echo ">> requirements.txt must include each image pytest plugin"
awk '
	/^    "pytest-xdist>=3.0",$/ {
		print
		print "    \"pytest-fixturecheck>=1.0\","
		next
	}
	{ print }
' "${WORKDIR}/pyproject.toml" > "${WORKDIR}/pyproject.toml.tmp"
mv "${WORKDIR}/pyproject.toml.tmp" "${WORKDIR}/pyproject.toml"
printf 'pytest-fixturecheck>=1.0\n' >> "${WORKDIR}/odh/requirements.in"
expect_failure "stale compiled image requirements" "compiled odh/requirements.txt"
reset_inputs

echo ">> requirements.txt must satisfy each image pytest plugin pin"
sed_in_place 's/pytest>=9.0.3/pytest>=99.0/' "${WORKDIR}/pyproject.toml"
sed_in_place 's/pytest>=9.0.3/pytest>=99.0/' "${WORKDIR}/odh/requirements.in"
expect_failure "stale compiled pytest version" "does not satisfy odh/requirements.in"
reset_inputs

echo ">> a pin that differs between the two files is drift"
sed_in_place 's/^pytest>=.*$/pytest>=1.0/' "${WORKDIR}/odh/requirements.in"
expect_failure "diverged pytest pin"
reset_inputs

echo ">> an image plugin absent from the dev group is drift"
printf 'pytest-subprocess>=1.0\n' >> "${WORKDIR}/odh/requirements.in"
expect_failure "image-only plugin"
reset_inputs

echo ">> the allowlisted exclusion is tolerated"
sed_in_place '/^    "pytest-cov>=4.0",$/d' "${WORKDIR}/pyproject.toml"
if ! "${PYTHON_BIN}" "${CHECK}" "${WORKDIR}" > /dev/null 2>&1; then
	echo "FAIL: allowlisted pytest-cov exclusion was rejected" >&2
	exit 1
fi
echo "ok: allowlisted exclusion tolerated"

echo "requirements mirror checks passed"
