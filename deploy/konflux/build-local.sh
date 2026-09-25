#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build Konflux images locally using Hermeto prefetched dependencies.
# Replicates the Konflux hermetic build pipeline (--network none).
#
# Prerequisites:
#   - hermeto and rpm (the RPM backend requires a Linux environment)
#   - podman
#
# Usage:
#   ./deploy/konflux/build-local.sh gateway
#   ./deploy/konflux/build-local.sh supervisor
#   ./deploy/konflux/build-local.sh sandbox
#   ./deploy/konflux/build-local.sh e2e-odh
#   ./deploy/konflux/build-local.sh all
#
# Override architecture (default: host arch via uname -m):
#   PLATFORM=linux/arm64 ./deploy/konflux/build-local.sh supervisor
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/hermeto-output"

# Detect or override platform
HOST_ARCH=$(uname -m)
case "${HOST_ARCH}" in
    x86_64)  DEFAULT_PLATFORM="linux/amd64" ;;
    aarch64) DEFAULT_PLATFORM="linux/arm64" ;;
    *)       DEFAULT_PLATFORM="linux/${HOST_ARCH}" ;;
esac
PLATFORM="${PLATFORM:-${DEFAULT_PLATFORM}}"

CLEANUP_PATHS=()
CONFIG_BACKUP_DIR="$(mktemp -d)"
cp -p "${REPO_ROOT}/.cargo/config.toml" "${CONFIG_BACKUP_DIR}/root-config.toml"
if [[ -f "${REPO_ROOT}/e2e/rust/.cargo/config.toml" ]]; then
    cp -p "${REPO_ROOT}/e2e/rust/.cargo/config.toml" "${CONFIG_BACKUP_DIR}/e2e-config.toml"
fi
cleanup() {
    cp -p "${CONFIG_BACKUP_DIR}/root-config.toml" "${REPO_ROOT}/.cargo/config.toml"
    if [[ -f "${CONFIG_BACKUP_DIR}/e2e-config.toml" ]]; then
        cp -p "${CONFIG_BACKUP_DIR}/e2e-config.toml" "${REPO_ROOT}/e2e/rust/.cargo/config.toml"
    else
        rm -f "${REPO_ROOT}/e2e/rust/.cargo/config.toml"
        rmdir "${REPO_ROOT}/e2e/rust/.cargo" 2>/dev/null || true
    fi
    for p in "${CLEANUP_PATHS[@]}"; do
        rm -rf "$p"
    done
    rm -rf "${CONFIG_BACKUP_DIR}"
}
trap cleanup EXIT

build_image() {
    local component="$1"
    local dockerfile konfig_dir output_dir repos_dir extra_cargo_input

    case "$component" in
        gateway)
            dockerfile="deploy/docker/Dockerfile.konflux.gateway"
            konfig_dir="deploy/konflux/gateway"
            ;;
        supervisor)
            dockerfile="deploy/docker/Dockerfile.konflux.supervisor"
            konfig_dir="deploy/konflux/supervisor"
            ;;
        sandbox)
            dockerfile="deploy/docker/Dockerfile.konflux.sandbox"
            konfig_dir="deploy/konflux/sandbox"
            ;;
        cli)
            dockerfile="deploy/docker/Dockerfile.konflux.cli"
            konfig_dir="deploy/konflux/cli"
            ;;
        e2e-odh)
            dockerfile="deploy/docker/Dockerfile.konflux.e2e-odh"
            konfig_dir="deploy/konflux/e2e-odh"
            ;;
        *)
            echo "Unknown component: $component" >&2
            exit 1
            ;;
    esac

    output_dir="${OUTPUT_DIR}/${component}"
    extra_cargo_input=""
    if [[ "${component}" == "e2e-odh" ]]; then
        extra_cargo_input='{"path": "e2e/rust", "type": "cargo"},'
    fi
    repos_dir=$(mktemp -d)
    CLEANUP_PATHS+=("${repos_dir}")

    echo "=== Prefetching ${component} dependencies ==="
    rm -rf "${output_dir}"
    hermeto fetch-deps \
        --source "${REPO_ROOT}" \
        --output "${output_dir}" \
        "[
            {\"path\": \".\", \"type\": \"cargo\"},
            ${extra_cargo_input}
            {\"path\": \"${konfig_dir}\", \"type\": \"rpm\"},
            {\"path\": \"${konfig_dir}\", \"type\": \"generic\", \"lockfile\": \"generic-fetcher.yaml\"}
        ]"

    echo "=== Injecting files ==="
    hermeto inject-files "${output_dir}" --for-output-dir /cachi2/output
    hermeto generate-env "${output_dir}" \
        --format env --for-output-dir /cachi2/output \
        --output "${output_dir}/cachi2.env"

    echo "=== Preparing RPM repos ==="
    find "${output_dir}" -name "hermeto.repo" -execdir cp {} cachi2.repo \;
    local rpm_arch
    case "${PLATFORM}" in
        */amd64|*/x86_64) rpm_arch="x86_64" ;;
        */arm64|*/aarch64) rpm_arch="aarch64" ;;
        *)                 rpm_arch=$(uname -m) ;;
    esac
    cp "${output_dir}/deps/rpm/${rpm_arch}/repos.d/cachi2.repo" "${repos_dir}/"
    chmod -R go+rX "${repos_dir}"

    echo "=== Building ${component} (--network none, platform ${PLATFORM}) ==="
    local hermetic_dockerfile
    hermetic_dockerfile=$(mktemp)
    CLEANUP_PATHS+=("${hermetic_dockerfile}")
    cp "${REPO_ROOT}/${dockerfile}" "${hermetic_dockerfile}"
    awk '/^[[:space:]]*RUN / { match($0, /RUN /); $0 = substr($0, 1, RSTART - 1) "RUN . /cachi2/cachi2.env && " sprintf("%c", 92) "\n    " substr($0, RSTART + RLENGTH) } { print }' "${hermetic_dockerfile}" > "${hermetic_dockerfile}.injected"
    mv "${hermetic_dockerfile}.injected" "${hermetic_dockerfile}"

    # Disable subscription-manager so it doesn't inject RHEL repos that fail
    # DNS under --network=none. Same as Konflux Tekton script (unlink rhel secrets).
    local sm_conf
    sm_conf=$(mktemp)
    CLEANUP_PATHS+=("${sm_conf}")
    echo -e "[main]\nenabled=0" > "${sm_conf}"

    # Podman auto-mounts host RHEL subscription secrets into /run/secrets/
    # via /usr/share/containers/mounts.conf. The redhat.repo there adds
    # rhel-* repos that can't resolve under --network=none. Mount an empty
    # directory over /run/secrets to neutralize the injection entirely.
    local empty_secrets
    empty_secrets=$(mktemp -d)
    CLEANUP_PATHS+=("${empty_secrets}")

    podman build \
        -f "${hermetic_dockerfile}" \
        --platform "${PLATFORM}" \
        --volume "$(realpath "${output_dir}"):/cachi2/output:Z" \
        --volume "$(realpath "${output_dir}/cachi2.env"):/cachi2/cachi2.env:Z" \
        --volume "$(realpath "${repos_dir}"):/etc/yum.repos.d:Z" \
        --volume "${sm_conf}:/etc/dnf/plugins/subscription-manager.conf:Z" \
        --volume "${empty_secrets}:/run/secrets:Z" \
        --network none \
        -t "openshell-${component}-konflux" \
        "${REPO_ROOT}"

    echo "=== ${component} built successfully ==="
    # The sandbox runtime image is ubi-micro without crypto-policies.
    if [[ "${component}" != "sandbox" && "${component}" != "e2e-odh" ]]; then
        test "$(podman run --rm --user=0 --entrypoint /usr/bin/update-crypto-policies "openshell-${component}-konflux" --show)" = "DEFAULT:PQ"
    fi
    if [[ "${component}" != "e2e-odh" ]]; then
        podman run --rm --platform "${PLATFORM}" "openshell-${component}-konflux" --help 2>&1 | head -3
    fi
    echo ""
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 {gateway|supervisor|sandbox|cli|e2e-odh|all}" >&2
    exit 1
fi

target="$1"
if [[ "$target" == "all" ]]; then
    build_image gateway
    build_image supervisor
    build_image sandbox
    build_image cli
else
    build_image "$target"
fi
