# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# RHEL 9 / UBI9 packaging for OpenShell (midstream CARRY).
#
# Unlike the upstream Fedora/EPEL spec at the repository root, this spec
# compiles the three binaries from source inside %%build against a vendored
# crate tarball, using only packages available from RHEL 9 channels
# (BaseOS, AppStream, CodeReady Builder) plus a rust toolchain newer than the
# one RHEL 9.8 ships. It never touches the network after %%prep.
#
# Build switches:
#   --without system_rust   toolchain is pre-installed under /usr/local
#                           (GitHub-hosted runners); drops the rust/cargo
#                           BuildRequires. Default: BuildRequires rust/cargo.
#   --with telemetry        keep upstream default features (telemetry on).
#                           Default: compiled out, like the Konflux images.
#
# The %%global version lines below are placeholders; make-sources.sh writes a
# stamped copy of this spec next to the source tarballs.

%bcond_without system_rust
%bcond_with telemetry

%global openshell_version 0.0.0
%global openshell_release 0
%global openshell_git_version 0.0.0
%global rust_min_version 1.94

# cargo strips release binaries (profile.release.strip = true) and vendored
# crates do not produce debugsource listings redhat-rpm-config accepts.
%global debug_package %{nil}

# The supervisor and CLI are linked static-PIE with `-C target-feature=+crt-static`.
# Keep redhat-rpm-config's hardened LDFLAGS/-specs out of those links; the
# Konflux images build with no distro flags at all, which is the tested baseline.
%undefine _auto_set_build_flags

%ifarch x86_64
%global rust_triple x86_64-unknown-linux-gnu
%endif
%ifarch aarch64
%global rust_triple aarch64-unknown-linux-gnu
%endif

%if %{with telemetry}
%global gateway_features --features bundled-z3
%global supervisor_features %{nil}
%else
%global gateway_features --no-default-features --features defaults-without-telemetry,bundled-z3
%global supervisor_features --no-default-features --features defaults-without-telemetry
%endif

Name:           openshell
Version:        %{openshell_version}
Release:        %{openshell_release}%{?dist}
Summary:        Safe, sandboxed runtimes for autonomous AI agents

License:        Apache-2.0
URL:            https://github.com/opendatahub-io/openshell
Source0:        openshell-%{openshell_version}.tar.gz
Source1:        openshell-%{openshell_version}-vendor.tar.xz
Source2:        openshell-gateway.service

ExclusiveArch:  x86_64 aarch64

%if %{with system_rust}
BuildRequires:  rust >= %{rust_min_version}
BuildRequires:  cargo >= %{rust_min_version}
%endif
# aws-lc-sys (C, cmake fallback) and libsqlite3-sys (C) build from vendored source.
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  cmake
# Bundled Z3 (gateway) is C++20 and needs <format>; RHEL 9 gcc 11 lacks it.
BuildRequires:  gcc-toolset-14
BuildRequires:  gcc-toolset-14-gcc-c++
# Static-PIE glibc link for the supervisor and CLI (CodeReady Builder).
BuildRequires:  glibc-static
BuildRequires:  systemd-rpm-macros
# readelf for the static-binary check in %%check.
BuildRequires:  binutils
BuildRequires:  tar
BuildRequires:  xz

# Runtime: container runtime for package-managed gateway sandboxes.
Recommends:     podman

%description
OpenShell provides safe, sandboxed runtimes for autonomous AI agents.
It offers a CLI for managing gateway registrations, sandboxes, and providers
with policy-enforced egress routing, credential proxying, and privacy-aware
profile-backed model-provider access.

# --- Gateway sub-package ---
%package gateway
Summary:        OpenShell gateway server with Podman sandbox driver
Requires:       podman
Requires:       openssl
Requires:       %{name} = %{version}-%{release}

%description gateway
OpenShell gateway server providing the control-plane API for sandbox
lifecycle management. This package installs Podman-oriented defaults in
gateway TOML while leaving compute driver selection to gateway auto-detection
or explicit operator configuration.

# --- Supervisor sub-package ---
%package supervisor
Summary:        Statically linked OpenShell sandbox supervisor binary

%description supervisor
Fully static (static-PIE glibc) openshell-sandbox supervisor binary that the
gateway injects into sandbox containers. The gateway compute drivers default to
pulling the supervisor from its OCI image (gateway setting supervisor_image);
this package is for hosts and image builds that want the binary on disk at
/usr/libexec/openshell/openshell-sandbox.

%prep
%autosetup -n %{name}-%{openshell_version} -p1

# Vendored crates (Source1) and offline cargo configuration. This replaces
# %%cargo_prep from cargo-rpm-macros, which RHEL 9 does not ship.
tar xf %{SOURCE1}
test -f vendor/z3-src-416.0.2/z3/CMakeLists.txt
mkdir -p .cargo
cat >> .cargo/config.toml <<'CARGO_EOF'

[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"

[net]
offline = true
CARGO_EOF

# Workspace version placeholder -> package version. This drives
# CARGO_PKG_VERSION, which the gateway uses as the default supervisor image tag.
sed -i 's/^version = "0.0.0"$/version = "%{openshell_version}"/' Cargo.toml
grep -q '^version = "%{openshell_version}"$' Cargo.toml
# Cargo.lock records the workspace members at the placeholder version; patch
# them the same way so `cargo build --locked` still holds.
sed -i 's/^version = "0.0.0"$/version = "%{openshell_version}"/' Cargo.lock
! grep -q '^version = "0.0.0"$' Cargo.lock

%build
export CARGO_HOME="$PWD/.cargo-home"
export CARGO_NET_OFFLINE=true
export OPENSHELL_GIT_VERSION="%{openshell_git_version}"
# openshell-core's build.rs prefers a git-derived version when it can find a
# repository. The build tree may live inside a checkout (CI, local builds), so
# stop git discovery at the rpmbuild BUILD directory to keep the stamped value.
export GIT_CEILING_DIRECTORIES="$(dirname "$PWD")"
%if %{without system_rust}
export PATH="/usr/local/bin:$PATH"
%endif
cargo --version
rustc --version

# CLI: static-PIE glibc, parity with the Konflux CLI image.
RUSTFLAGS="-C target-feature=+crt-static" \
cargo build --release --offline --locked \
    --target %{rust_triple} \
    --package openshell-cli

# Gateway: dynamic glibc. gcc-toolset-14 only for this step (bundled Z3).
(
    export PATH="/opt/rh/gcc-toolset-14/root/usr/bin:$PATH"
    export LD_LIBRARY_PATH="/opt/rh/gcc-toolset-14/root/usr/lib64:/opt/rh/gcc-toolset-14/root/usr/lib"
    cargo build --release --offline --locked \
        --package openshell-gateway \
        %{gateway_features}
)

# Supervisor: static-PIE glibc, injected into arbitrary sandbox containers.
RUSTFLAGS="-C target-feature=+crt-static" \
cargo build --release --offline --locked \
    --target %{rust_triple} \
    --package openshell-sandbox \
    %{supervisor_features}

# Vendored crate inventory (stand-in for %%cargo_vendor_manifest).
( cd vendor && ls -1 | sed -E 's/^(.*)-([0-9][^-]*)$/bundled(crate(\1)) = \2/' ) > cargo-vendor.txt

%install
install -Dpm 0755 target/%{rust_triple}/release/openshell %{buildroot}%{_bindir}/openshell
install -Dpm 0755 target/release/openshell-gateway %{buildroot}%{_bindir}/openshell-gateway
install -Dpm 0755 target/%{rust_triple}/release/openshell-sandbox %{buildroot}%{_libexecdir}/openshell/openshell-sandbox

# Default gateway TOML template; the user unit seeds ~/.config/openshell/gateway.toml from it.
install -Dpm 0644 deploy/rpm/gateway.toml.default %{buildroot}%{_datadir}/openshell-gateway/gateway.toml.default

# Gateway systemd user unit: systemctl --user enable --now openshell-gateway.service
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_userunitdir}/openshell-gateway.service

install -d %{buildroot}%{_docdir}/openshell-gateway
install -pm 0644 deploy/rpm/QUICKSTART.md deploy/rpm/CONFIGURATION.md deploy/rpm/TROUBLESHOOTING.md \
    %{buildroot}%{_docdir}/openshell-gateway/

%check
%{buildroot}%{_bindir}/openshell --version | grep -F '%{openshell_git_version}'
%{buildroot}%{_bindir}/openshell-gateway --version
%{buildroot}%{_libexecdir}/openshell/openshell-sandbox --version

# Both static binaries must have no PT_INTERP and no DT_NEEDED.
bash tasks/scripts/verify-static-binary.sh \
    %{buildroot}%{_libexecdir}/openshell/openshell-sandbox \
    %{buildroot}%{_bindir}/openshell

# The gateway must not link anything from the gcc-toolset-14 prefix.
! readelf -d %{buildroot}%{_bindir}/openshell-gateway | grep -q '/opt/rh/'

test -f %{buildroot}%{_datadir}/openshell-gateway/gateway.toml.default
grep -q 'gateway.toml.default' %{buildroot}%{_userunitdir}/openshell-gateway.service

%post gateway
%systemd_user_post openshell-gateway.service

%preun gateway
%systemd_user_preun openshell-gateway.service

%postun gateway
%systemd_user_postun_with_restart openshell-gateway.service

%files
%license LICENSE
%doc README.md
%doc cargo-vendor.txt
%{_bindir}/openshell

%files gateway
%license LICENSE
%doc %{_docdir}/openshell-gateway/QUICKSTART.md
%doc %{_docdir}/openshell-gateway/CONFIGURATION.md
%doc %{_docdir}/openshell-gateway/TROUBLESHOOTING.md
%{_bindir}/openshell-gateway
%{_userunitdir}/openshell-gateway.service
%dir %{_datadir}/openshell-gateway
%{_datadir}/openshell-gateway/gateway.toml.default

%files supervisor
%license LICENSE
%dir %{_libexecdir}/openshell
%{_libexecdir}/openshell/openshell-sandbox

%changelog
* Thu Sep 10 2026 Open Data Hub <managed-open-data-hub@redhat.com> - 0.0.0-0
- Initial RHEL 9 packaging of openshell, openshell-gateway and openshell-supervisor
