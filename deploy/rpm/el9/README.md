# EL9 RPM packaging

RHEL 9 / UBI9 packages for the three OpenShell binaries, built from source
inside `rpmbuild`:

| Package | Contents |
|---|---|
| `openshell` | `/usr/bin/openshell` CLI, static-PIE glibc |
| `openshell-gateway` | `/usr/bin/openshell-gateway` (dynamic glibc), systemd user unit, `gateway.toml.default`, docs |
| `openshell-supervisor` | `/usr/libexec/openshell/openshell-sandbox`, static-PIE glibc |

The upstream spec at the repository root repackages prebuilt binaries for
Fedora and EPEL 10 and is left untouched. This directory is midstream-only.

## Toolchain

The workspace MSRV (1.94) is newer than the rust RHEL 9.8 ships (1.92.0), so
the build needs one of:

- `rust`/`cargo` RPMs from a RHEL AI compose repository (internal GitLab
  runners, see `Containerfile.builder`), or
- the upstream toolchain tarball from static.rust-lang.org installed under
  `/usr/local`, with `rpmbuild --without system_rust` (GitHub-hosted runners,
  local builds).

Everything else comes from BaseOS, AppStream and CodeReady Builder
(`glibc-static`). No EPEL: `cargo-rpm-macros` and `pandoc` are not used, so
the spec carries its own vendored-cargo setup and ships no man pages.

## Local build

```shell
podman run --rm -it -v "$PWD":/src:Z -w /src registry.access.redhat.com/ubi9/ubi:9.8 bash
dnf install -y --enablerepo=ubi-9-codeready-builder-rpms rpm-build rpmdevtools \
    gcc gcc-c++ make cmake gcc-toolset-14 gcc-toolset-14-gcc-c++ glibc-static \
    systemd-rpm-macros binutils git-core tar xz
curl -fsSLO https://static.rust-lang.org/dist/rust-1.95.0-x86_64-unknown-linux-gnu.tar.xz
tar xJf rust-1.95.0-x86_64-unknown-linux-gnu.tar.xz
rust-1.95.0-x86_64-unknown-linux-gnu/install.sh --prefix=/usr/local
deploy/rpm/el9/make-sources.sh            # needs network: cargo vendor
deploy/rpm/el9/build-rpm.sh --without system_rust
deploy/rpm/el9/smoke-test.sh deploy/rpm/el9/_rpmbuild/RPMS
```

`make-sources.sh` writes `openshell-<version>.tar.gz`, the vendored crates
tarball, the unit file and a version-stamped copy of the spec into
`deploy/rpm/el9/_sources/`. `build-rpm.sh` runs `rpmbuild -bs` and `-bb`
offline against that directory. Wrap it in `unshare -rn` to prove no network
is needed.

## Versioning

`make-sources.sh` derives the identity from `git describe`:

- tag `v0.0.116-rhaiv.2` on HEAD: Version `0.0.116`, Release `1.rhaiv.2.el9`
- 12 commits after it: Release `1.rhaiv.2.12.git<sha>.el9`
- `--version` prints the tag (or `<tag>.dev.<distance>+g<sha>`)

Override with `OPENSHELL_RPM_VERSION`, `OPENSHELL_RPM_RELEASE`,
`OPENSHELL_GIT_VERSION`.

## CI

- GitHub: `.github/workflows/rpm-el9.yml` builds x86_64 and aarch64 on
  GitHub-hosted runners in a UBI9 container with the toolchain tarball, then
  installs the RPMs into a fresh UBI9 container and runs `smoke-test.sh`.
- GitLab: `.gitlab-ci.yml` (repository root) is meant for a GitLab project
  that pull-mirrors this repository. It builds `Containerfile.builder` with
  the RHEL AI compose repo file and internal CA supplied as CI file variables,
  builds both architectures with `rust` from that compose, and publishes the
  RPMs to the project's generic package registry.

## Notes

- The gateway defaults its supervisor image to
  `ghcr.io/nvidia/openshell/supervisor:<version>`; set `supervisor_image` in
  `~/.config/openshell/gateway.toml` to use the ODH supervisor image or the
  binary shipped by `openshell-supervisor`.
- The CLI and supervisor statically link glibc (LGPL-2.1-or-later). The SRPM
  is built alongside the binary RPMs so the sources can be redistributed.
- Debuginfo is disabled (`profile.release.strip = true`).
- Product builds later go through the Konflux `rpmbuild-pipeline` with
  `monorepo-subdir: deploy/rpm/el9`; the spec's defaults (`system_rust` on,
  telemetry off) are the intended product configuration.
