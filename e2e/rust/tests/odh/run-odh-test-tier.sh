#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Single entrypoint for tiered ODH e2e execution, both locally and in CI.
#
# Reads tiers.toml (co-located with this script) to determine which upstream
# test binaries and ODH test modules belong to the given tier, runs them, and
# then runs the image provenance test regardless of tier (it's a property of
# the deployment, not of any one tier).
#
# Usage:
#   e2e/rust/tests/odh/run-odh-test-tier.sh <tier>
#
# Env:
#   ALLOWED_IMAGE_REGISTRY_PREFIXES  Required by the provenance test unless
#                                    it's skipped; see smoke/image_provenance.rs.
#   NAMESPACE, RELEASE               Read by the provenance test (defaults:
#                                    openshell, openshell).
#   SKIP_IMAGE_PROVENANCE=1          Skip the provenance test (local iteration).
#   ODH_SELINUX_AUDIT                Set to 1 to run every selected test under
#                                    the repository-owned AVC-audit wrapper.
#   ODH_SKIP_UPSTREAM_TESTS          Comma-separated upstream test binaries to
#                                    skip for a lane-specific environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TIERS_FILE="${SCRIPT_DIR}/tiers.toml"

TIER="${1:-}"

log()  { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

if [ -z "$TIER" ]; then
  fail "usage: $0 <tier>. Available tiers: $(python3 -c '
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(" ".join(sorted(tomllib.load(f))))
' "$TIERS_FILE")"
fi

tier_config="$(python3 - "$TIERS_FILE" "$TIER" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    tiers = tomllib.load(f)

tier = sys.argv[2]
if tier not in tiers:
    print(f"unknown tier {tier!r}; available: {', '.join(sorted(tiers))}", file=sys.stderr)
    sys.exit(1)

cfg = tiers[tier]
print(" ".join(cfg.get("upstream_tests", [])))
print(cfg.get("odh_filter", ""))
PY
)"

readarray -t tier_config_lines <<< "$tier_config"
read -ra UPSTREAM_TESTS <<< "${tier_config_lines[0]:-}"
ODH_FILTER="${tier_config_lines[1]:-}"

overall_status=0

should_skip_upstream_test() {
  local test_bin="$1" skipped
  IFS=',' read -ra skipped_tests <<< "${ODH_SKIP_UPSTREAM_TESTS:-}"
  for skipped in "${skipped_tests[@]}"; do
    [ "$skipped" = "$test_bin" ] && return 0
  done
  return 1
}

run_selected_tests() {
  local test_bin="$1" filter="$2" test_name test_list
  local list_args=(cargo test --manifest-path "${ROOT}/e2e/rust/Cargo.toml" --features e2e-odh --test "$test_bin" --)
  [ -z "$filter" ] || list_args+=("$filter")
  list_args+=(--list)

  if [ "${ODH_SELINUX_AUDIT:-0}" != "1" ]; then
    log "Running ${test_bin} tests matching: ${filter:-all}"
    if ! cargo test --manifest-path "${ROOT}/e2e/rust/Cargo.toml" \
        --features e2e-odh --test "$test_bin" -- ${filter:+"$filter"} --nocapture; then
      overall_status=1
    fi
    return
  fi

  if ! test_list="$("${list_args[@]}")"; then
    overall_status=1
    return
  fi
  while IFS= read -r test_name; do
    [ -n "$test_name" ] || continue
    log "Running audited scenario: ${test_bin}:${test_name}"
    if ! "${SCRIPT_DIR}/run-selinux-enforcing.sh" "${TIER}:${test_bin}:${test_name}" \
        cargo test --manifest-path "${ROOT}/e2e/rust/Cargo.toml" \
        --features e2e-odh --test "$test_bin" -- "$test_name" --exact --nocapture; then
      overall_status=1
    fi
  done < <(printf '%s\n' "$test_list" | sed -n 's/: test$//p')
}

for test_bin in "${UPSTREAM_TESTS[@]:-}"; do
  [ -n "$test_bin" ] || continue
  if should_skip_upstream_test "$test_bin"; then
    log "Skipping upstream test binary: $test_bin"
    continue
  fi
  run_selected_tests "$test_bin" ""
done

if [ -n "$ODH_FILTER" ]; then
  run_selected_tests odh "$ODH_FILTER"
fi

if [ "${SKIP_IMAGE_PROVENANCE:-0}" = "1" ]; then
  log "Skipping image provenance check (SKIP_IMAGE_PROVENANCE=1)"
elif [[ "smoke::image_provenance::" == "$ODH_FILTER"* ]]; then
  log "Image provenance already covered by tier filter: $ODH_FILTER"
else
  log "Verifying image provenance"
  run_selected_tests odh "smoke::image_provenance::"
fi

exit "$overall_status"
