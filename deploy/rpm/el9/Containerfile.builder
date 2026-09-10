# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# UBI9 builder image for deploy/rpm/el9/openshell.spec on internal GitLab
# runners. RHEL 9.8 ships rust 1.92.0, below the workspace MSRV, so the rust
# toolchain comes from an internal RHEL AI compose repository.
#
# Build secrets/args (provided by GitLab CI, never committed):
#   --secret id=rhelai_repo,src=<repo file>   dnf repo file for the RHEL AI compose
#   --secret id=rh_it_ca,src=<pem>            internal root CA for the compose host
#   --build-arg RHELAI_VERSION=3.5            written to /etc/dnf/vars/rhelaiver
#   --build-arg RUST_MIN_VERSION=1.94
#
# Public repositories (BaseOS, AppStream, CodeReady Builder) come from the UBI
# image's own ubi.repo.
FROM registry.access.redhat.com/ubi9/ubi:9.8@sha256:25a147defd01e19674714f55d17538c8dbe55d8c305fa157ecc3f9c8977b05b6

ARG RHELAI_VERSION=3.5
ARG RUST_MIN_VERSION=1.94

RUN echo "${RHELAI_VERSION}" > /etc/dnf/vars/rhelaiver \
    && sed -i '/^enabled=/s/=1/=0/' /etc/dnf/plugins/subscription-manager.conf

RUN --mount=type=secret,id=rhelai_repo,target=/etc/yum.repos.d/rhelai.repo \
    --mount=type=secret,id=rh_it_ca,target=/etc/pki/ca-trust/source/anchors/rh-it-root-ca.pem \
    update-ca-trust \
    && dnf install -y --nodocs --setopt=install_weak_deps=0 \
        --enablerepo=ubi-9-codeready-builder-rpms \
        "rust >= ${RUST_MIN_VERSION}" "cargo >= ${RUST_MIN_VERSION}" \
        rpm-build rpmdevtools rpmlint createrepo_c \
        gcc gcc-c++ make cmake \
        gcc-toolset-14 gcc-toolset-14-gcc-c++ \
        glibc-static systemd-rpm-macros binutils \
        git-core tar xz \
    && dnf clean all \
    && cargo --version

WORKDIR /work
