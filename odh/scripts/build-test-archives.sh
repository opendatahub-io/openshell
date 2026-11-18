#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output=${1:?usage: build-test-archives.sh OUTPUT_DIRECTORY}
mkdir -p "${output}"
output="$(cd "${output}" && pwd)"

# Remote OpenShift pods cannot generally reach the test runner host. Intentionally
# omit e2e-host-gateway; runtime feature requests must match this compiled archive.
cargo nextest archive --locked \
  --manifest-path "${ROOT}/e2e/rust/Cargo.toml" \
  --target-dir "${ROOT}/e2e/rust/target" \
  --features e2e,e2e-kubernetes \
  --archive-file "${output}/e2e-kubernetes.tar.zst"
"${PYTHON_BIN:-python3}" "${ROOT}/odh/scripts/test-archive.py" write \
  "${output}/e2e-kubernetes.tar.zst" kubernetes e2e,e2e-kubernetes

cargo nextest archive --locked \
  --manifest-path "${ROOT}/tests/suites/conformance/Cargo.toml" \
  --package conformance \
  --archive-file "${output}/e2e-conformance.tar.zst"
"${PYTHON_BIN:-python3}" "${ROOT}/odh/scripts/test-archive.py" write \
  "${output}/e2e-conformance.tar.zst" conformance
