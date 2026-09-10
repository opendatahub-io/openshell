#!/usr/bin/env bash
# Install the upstream Rust toolchain tarball under /usr/local for EL9 RPM
# builds on GitHub-hosted runners (RHEL 9.8 ships rust 1.92.0, below the
# workspace MSRV). Checksums match deploy/konflux/*/generic-fetcher.yaml.
#
# Usage: rpm-el9-install-rust.sh <x86_64|aarch64>
set -euo pipefail

arch="${1:?arch required}"
version="${RUST_VERSION:-1.95.0}"
case "${version}-${arch}" in
    1.95.0-x86_64)  sha256=2e0338f18ecbaa4a0f631b9e80e8b8e26bb6fe77dd5454fba8a70cf96c1e84a1 ;;
    1.95.0-aarch64) sha256=094c9c36531911c5cc7dd6ab2d3069ab8dcd744d6239b0bda1387b243dfc391e ;;
    *) echo "no checksum recorded for rust ${version} ${arch}" >&2; exit 1 ;;
esac

tarball="rust-${version}-${arch}-unknown-linux-gnu.tar.xz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 5 -o "${tmp}/${tarball}" "https://static.rust-lang.org/dist/${tarball}"
echo "${sha256}  ${tmp}/${tarball}" | sha256sum -c -
mkdir -p "${tmp}/rust"
tar xJf "${tmp}/${tarball}" -C "${tmp}/rust" --strip-components=1
"${tmp}/rust/install.sh" --prefix=/usr/local --without=rust-docs
/usr/local/bin/cargo --version
