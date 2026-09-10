#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Install the EL9 RPMs into the current (UBI9/RHEL9) system and verify them.
# Intended to run inside a fresh ubi9 container, as root.
#
# Usage:
#   deploy/rpm/el9/smoke-test.sh RPM_DIR [EXPECTED_GIT_VERSION]
set -euo pipefail

RPM_DIR="${1:?RPM_DIR required}"
EXPECTED="${2:-}"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

mapfile -t rpms < <(find "$RPM_DIR" -name '*.rpm' ! -name '*.src.rpm' | sort)
[[ ${#rpms[@]} -gt 0 ]] || { echo "no RPMs under ${RPM_DIR}" >&2; exit 1; }

dnf install -y --setopt=install_weak_deps=0 binutils "${rpms[@]}"

echo "=== versions ==="
openshell --version
openshell-gateway --version
/usr/libexec/openshell/openshell-sandbox --version
if [[ -n "$EXPECTED" ]]; then
    openshell --version | grep -F "$EXPECTED"
fi

echo "=== static binaries ==="
bash "${REPO_ROOT}/tasks/scripts/verify-static-binary.sh" \
    /usr/libexec/openshell/openshell-sandbox /usr/bin/openshell

echo "=== package requires ==="
rpm -q --requires openshell-supervisor | tee /dev/stderr | { ! grep -q 'lib.*\.so'; }
rpm -q --requires openshell-gateway | tee /dev/stderr | { ! grep -q '/opt/rh/'; }
rpm -q --requires openshell | tee /dev/stderr | { ! grep -q 'lib.*\.so'; }

echo "=== gateway unit ==="
# No user manager runs inside a container, so check the unit statically.
unit=/usr/lib/systemd/user/openshell-gateway.service
test -f "$unit"
grep -q '^ExecStart=/usr/bin/openshell-gateway$' "$unit"
grep -q 'generate-certs' "$unit"
grep -q 'gateway.toml.default' "$unit"
grep -q '^WantedBy=default.target$' "$unit"
test -f /usr/share/openshell-gateway/gateway.toml.default
test -f /usr/share/doc/openshell-gateway/QUICKSTART.md

echo "smoke test passed"
