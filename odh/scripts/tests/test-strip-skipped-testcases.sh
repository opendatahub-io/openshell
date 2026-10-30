#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Exercise strip-skipped-testcases.py: skipped cases are removed, the suite
# attributes are recomputed from the surviving cases (so the report stays
# self-consistent after the merge script recalculates root totals), a fully
# skipped report exits 1 for the vacuous-pass check, and malformed XML
# exits 2 instead of crashing with a traceback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../strip-skipped-testcases.py"

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3)}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

cat > "${WORKDIR}/mixed.xml" <<'XML'
<?xml version="1.0"?>
<testsuite name="python" tests="3" skipped="1" failures="1" errors="0" time="2.5">
  <testcase name="passes" classname="t" time="1.0"/>
  <testcase name="fails" classname="t" time="1.0"><failure message="boom"/></testcase>
  <testcase name="skips" classname="t" time="0.5"><skipped type="pytest.skip"/></testcase>
</testsuite>
XML

if ! "${PYTHON_BIN}" "${HELPER}" "${WORKDIR}/mixed.xml" 2>"${WORKDIR}/stderr.log"; then
	echo "FAIL: mixed report exited nonzero, expected 0" >&2
	cat "${WORKDIR}/stderr.log" >&2
	exit 1
fi
grep -q "stripped 1 skipped" "${WORKDIR}/stderr.log" || {
	echo "FAIL: audit line for the stripped case missing" >&2
	exit 1
}
remaining="$(grep -c "<testcase" "${WORKDIR}/mixed.xml")"
[[ "${remaining}" == 2 ]] || { echo "FAIL: expected 2 surviving cases, found ${remaining}" >&2; exit 1; }
for expected in 'tests="2"' 'skipped="0"' 'failures="1"' 'errors="0"'; do
	grep -q -- "${expected}" "${WORKDIR}/mixed.xml" || {
		echo "FAIL: suite attribute ${expected} not recomputed from surviving cases" >&2
		exit 1
	}
done
grep -q 'time="2.000000"' "${WORKDIR}/mixed.xml" || {
	echo "FAIL: suite time not recomputed from surviving cases" >&2
	exit 1
}
grep -q '^    <testcase' "${WORKDIR}/mixed.xml" || {
	echo "FAIL: stripped report was not written with readable indentation" >&2
	exit 1
}
echo "ok: mixed report stripped with consistent attributes"

cat > "${WORKDIR}/all-skipped.xml" <<'XML'
<?xml version="1.0"?>
<testsuite name="python" tests="2" skipped="2" failures="0" errors="0" time="0.1">
  <testcase name="a" classname="t" time="0.05"><skipped/></testcase>
  <testcase name="b" classname="t" time="0.05"><skipped/></testcase>
</testsuite>
XML
if "${PYTHON_BIN}" "${HELPER}" "${WORKDIR}/all-skipped.xml" 2>/dev/null; then
	echo "FAIL: fully skipped report exited 0, expected 1 (vacuous pass)" >&2
	exit 1
else
	status=$?
	[[ "${status}" == 1 ]] || { echo "FAIL: fully skipped report exited ${status}, expected 1" >&2; exit 1; }
fi
[[ "$(grep -c "<testcase" "${WORKDIR}/all-skipped.xml")" == 0 ]] || {
	echo "FAIL: fully skipped report kept skipped cases" >&2
	exit 1
}
echo "ok: fully skipped report exits 1"

printf '<testsuite name="broken" tests="1"><testcase' > "${WORKDIR}/malformed.xml"
if "${PYTHON_BIN}" "${HELPER}" "${WORKDIR}/malformed.xml" 2>"${WORKDIR}/malformed.log"; then
	echo "FAIL: malformed report exited 0, expected 2" >&2
	exit 1
else
	status=$?
	[[ "${status}" == 2 ]] || { echo "FAIL: malformed report exited ${status}, expected 2" >&2; exit 1; }
fi
grep -q "cannot parse" "${WORKDIR}/malformed.log" || {
	echo "FAIL: malformed report error was not clear" >&2
	exit 1
}
echo "ok: malformed report exits 2 with a clear error"

if "${PYTHON_BIN}" "${HELPER}" "${WORKDIR}" 2>"${WORKDIR}/io-error.log"; then
	echo "FAIL: directory report exited 0, expected 2" >&2
	exit 1
else
	status=$?
	[[ "${status}" == 2 ]] || { echo "FAIL: directory report exited ${status}, expected 2" >&2; exit 1; }
fi
grep -q "cannot read or write" "${WORKDIR}/io-error.log" || {
	echo "FAIL: I/O report error was not clear" >&2
	exit 1
}
echo "ok: I/O errors exit 2 with a clear error"

echo "strip-skipped-testcases checks passed"
