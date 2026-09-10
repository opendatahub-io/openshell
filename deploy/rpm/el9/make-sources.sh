#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Prepare the inputs for deploy/rpm/el9/openshell.spec: derive the package
# version from git, create the source tarball and the vendored-crates tarball,
# copy the systemd unit, and write a version-stamped copy of the spec.
#
# This is the only step that needs network access (cargo vendor). Everything
# rpmbuild does afterwards is offline.
#
# Usage:
#   deploy/rpm/el9/make-sources.sh [-o OUTPUT_DIR] [--reuse-vendor]
#
# Environment overrides (all optional):
#   OPENSHELL_RPM_VERSION   RPM Version (X.Y.Z)
#   OPENSHELL_RPM_RELEASE   RPM Release without %{?dist}
#   OPENSHELL_GIT_VERSION   value stamped into the binaries (--version)
#   SOURCE_DATE_EPOCH       tarball mtime (defaults to the commit date)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SPEC_SRC="${REPO_ROOT}/deploy/rpm/el9/openshell.spec"
OUT="${REPO_ROOT}/deploy/rpm/el9/_sources"
REUSE_VENDOR=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output) OUT="$2"; shift 2 ;;
        --reuse-vendor) REUSE_VENDOR=1; shift ;;
        -h|--help) sed -n '5,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$REPO_ROOT"

# --- Version derivation -----------------------------------------------------
# Tags are vX.Y.Z (upstream) or vX.Y.Z-rhaiv.N (midstream). Upstream
# pre-release tags (v*-pre.*) are skipped.
describe="$(git describe --tags --long --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude 'v*-pre.*' HEAD)"
# describe = vX.Y.Z[-rhaiv.N]-<distance>-g<sha>
sha="${describe##*-g}"
rest="${describe%-g*}"
distance="${rest##*-}"
tag="${rest%-*}"
tag="${tag#v}"
base_version="${tag%%-*}"
suffix=""
if [[ "$tag" == *-* ]]; then
    suffix="${tag#*-}"          # e.g. rhaiv.2
fi

version="${OPENSHELL_RPM_VERSION:-$base_version}"
release_base="1"
[[ -n "$suffix" ]] && release_base="1.${suffix}"
if [[ "$distance" != "0" ]]; then
    release_base="${release_base}.${distance}.git${sha}"
fi
release="${OPENSHELL_RPM_RELEASE:-$release_base}"

if [[ "$distance" == "0" ]]; then
    git_version_default="$tag"
else
    git_version_default="${tag}.dev.${distance}+g${sha}"
fi
git_version="${OPENSHELL_GIT_VERSION:-$git_version_default}"

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct HEAD)}"
lock_hash="$(sha256sum Cargo.lock | cut -c1-16)"

echo "VERSION=${version}"
echo "RELEASE=${release}"
echo "GIT_VERSION=${git_version}"
echo "CARGO_LOCK_HASH=${lock_hash}"
{
    echo "OPENSHELL_RPM_VERSION=${version}"
    echo "OPENSHELL_RPM_RELEASE=${release}"
    echo "OPENSHELL_GIT_VERSION=${git_version}"
    echo "OPENSHELL_CARGO_LOCK_HASH=${lock_hash}"
} > "${OUT}/build.env"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "version=${version}"
        echo "release=${release}"
        echo "git_version=${git_version}"
        echo "cargo_lock_hash=${lock_hash}"
    } >> "$GITHUB_OUTPUT"
fi

tar_opts=(--sort=name --owner=0 --group=0 --numeric-owner --mtime="@${SOURCE_DATE_EPOCH}")

# --- Source0: tracked files only, rooted at openshell-<version>/ -------------
src_dir="openshell-${version}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "${tmp}/${src_dir}"
git ls-files -z | xargs -0 tar cf - | tar xf - -C "${tmp}/${src_dir}/"
tar "${tar_opts[@]}" -czf "${OUT}/${src_dir}.tar.gz" -C "$tmp" "$src_dir"
echo "wrote ${OUT}/${src_dir}.tar.gz"

# --- Source1: vendored crates -----------------------------------------------
vendor_tar="${OUT}/${src_dir}-vendor.tar.xz"
vendor_stamp="${OUT}/${src_dir}-vendor.tar.xz.lock-${lock_hash}"
if [[ "$REUSE_VENDOR" == "1" && -f "$vendor_tar" && -f "$vendor_stamp" ]]; then
    echo "reusing ${vendor_tar} (Cargo.lock ${lock_hash})"
else
    rm -f "${OUT}"/*-vendor.tar.xz "${OUT}"/*-vendor.tar.xz.lock-*
    vendor_dir="${tmp}/vendor"
    CARGO_HTTP_TIMEOUT=600 CARGO_NET_RETRY=5 \
        cargo vendor --quiet --locked --versioned-dirs "$vendor_dir"
    test -f "${vendor_dir}/z3-src-416.0.2/z3/CMakeLists.txt"
    XZ_OPT="-T0" tar "${tar_opts[@]}" -cJf "$vendor_tar" -C "$tmp" vendor
    touch "$vendor_stamp"
    echo "wrote ${vendor_tar}"
fi

# --- Source2 + stamped spec -------------------------------------------------
cp "${REPO_ROOT}/deploy/rpm/el9/openshell-gateway.service" "${OUT}/"
sed -e "s/^%global openshell_version .*/%global openshell_version ${version}/" \
    -e "s/^%global openshell_release .*/%global openshell_release ${release}/" \
    -e "s/^%global openshell_git_version .*/%global openshell_git_version ${git_version}/" \
    -e "s/^\(\* .*\) - 0\.0\.0-0$/\1 - ${version}-${release}/" \
    "$SPEC_SRC" > "${OUT}/openshell.spec"
grep -q "^%global openshell_version ${version}$" "${OUT}/openshell.spec"

( cd "$OUT" && sha256sum "${src_dir}.tar.gz" "${src_dir}-vendor.tar.xz" openshell-gateway.service > SHA256SUMS )
echo "sources ready in ${OUT}"
