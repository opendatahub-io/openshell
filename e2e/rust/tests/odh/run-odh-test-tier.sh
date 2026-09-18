#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TIERS_FILE="${SCRIPT_DIR}/tiers.toml"
TIER="${1:-}"

log()  { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

if [ -z "${TIER}" ]; then
  fail "usage: $0 <tier>. Available tiers: $(python3 -c '
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(" ".join(sorted(tomllib.load(f))))
' "$TIERS_FILE")"
fi

tier_config="$(python3 - "${TIERS_FILE}" "${TIER}" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    tiers = tomllib.load(f)

tier = sys.argv[2]
if tier not in tiers:
    print(f"unknown tier {tier!r}", file=sys.stderr)
    sys.exit(1)

cfg = tiers[tier]
print(" ".join(cfg.get("upstream_tests", [])))
print(cfg.get("odh_filter", ""))
PY
)"

readarray -t tier_config_lines <<< "${tier_config}"
read -ra UPSTREAM_TESTS <<< "${tier_config_lines[0]:-}"
ODH_FILTER="${tier_config_lines[1]:-}"

overall_status=0

for test_bin in "${UPSTREAM_TESTS[@]:-}"; do
  [ -n "$test_bin" ] || continue
  log "Running upstream test binary: $test_bin"
  if ! cargo test --manifest-path "${ROOT}/e2e/rust/Cargo.toml" \
      --features e2e-odh --test "$test_bin" -- --nocapture; then
    overall_status=1
  fi
done

if [ -n "${ODH_FILTER}" ]; then
  log "Running ODH tests matching: $ODH_FILTER"
  cargo test --manifest-path "${ROOT}/e2e/rust/Cargo.toml" \
    --features e2e-odh --test odh -- "$ODH_FILTER" --nocapture || overall_status=1
fi

if [ "${SKIP_IMAGE_PROVENANCE:-0}" = "1" ]; then
  log "Skipping image provenance check (SKIP_IMAGE_PROVENANCE=1)"
elif [[ "smoke::image_provenance::" == "${ODH_FILTER}"* ]]; then
  log "Image provenance already covered by tier filter: $ODH_FILTER"
else
  log "Verifying image provenance"
  cargo test --manifest-path "${ROOT}/e2e/rust/Cargo.toml" \
    --features e2e-odh --test odh -- smoke::image_provenance:: --nocapture || overall_status=1
fi

exit "$overall_status"
