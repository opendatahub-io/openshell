#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build the EL9 SRPM and binary RPMs from the outputs of make-sources.sh.
# Runs entirely offline.
#
# Usage:
#   deploy/rpm/el9/build-rpm.sh [-s SOURCES_DIR] [-t TOPDIR] [rpmbuild options...]
#
# Examples:
#   deploy/rpm/el9/build-rpm.sh                          # rust/cargo from RPMs
#   deploy/rpm/el9/build-rpm.sh --without system_rust    # rust under /usr/local
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SOURCES="${REPO_ROOT}/deploy/rpm/el9/_sources"
TOPDIR="${REPO_ROOT}/deploy/rpm/el9/_rpmbuild"
EXTRA=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--sources) SOURCES="$2"; shift 2 ;;
        -t|--topdir) TOPDIR="$2"; shift 2 ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done
SOURCES="$(cd "$SOURCES" && pwd)"
mkdir -p "$TOPDIR"
TOPDIR="$(cd "$TOPDIR" && pwd)"
SPEC="${SOURCES}/openshell.spec"
test -f "$SPEC" || { echo "missing ${SPEC}; run make-sources.sh first" >&2; exit 1; }

defines=(--define "_topdir ${TOPDIR}" --define "_sourcedir ${SOURCES}")

rpmbuild -bs "${defines[@]}" "${EXTRA[@]}" "$SPEC"
rpmbuild -bb "${defines[@]}" "${EXTRA[@]}" "$SPEC"

echo "=== Built packages ==="
find "${TOPDIR}/RPMS" "${TOPDIR}/SRPMS" -name '*.rpm' -print
