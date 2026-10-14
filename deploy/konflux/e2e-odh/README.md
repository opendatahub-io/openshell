# ODH E2E Image Build

The ODH Konflux e2e image is a separate test artifact. Its
multi-stage UBI9 build compiles the CLI and a nextest archive from two
independent Cargo lockfiles on the Red Hat rust-builder image, with crates,
RPMs, and cluster tools prefetched by Hermeto for a network-isolated build. The runtime image carries the compiled
archive, Cargo and nextest executables, cluster tools, the SSH client needed
by sandbox lifecycle tests, and Git for repository workloads.

At runtime, the image entrypoint uses the Quay deployment script to create a
gateway on the target OpenShift cluster, runs one selected test tier, writes
JUnit and HTML reports to a mounted results directory, and tears down the
deployment. Cleanup is armed before deployment and tracks namespace creation
separately from local gateway registration, so rollout failures remove the
owned namespace and validation failures preserve local registration. Signals
are forwarded through the tier runner to nextest before teardown. Extracted
client mTLS material is stored in a mode `0700` directory with mode `0600`
files. The Rust tests consume the deployed gateway.

The image also carries a fully prefetched Python 3.11 test environment and
generated protobuf bindings, so the `sdk` and `gateway-e2e` Python test modes
run without runtime dependency downloads. See
[Python test modes](../../../e2e/rust/tests/odh/README.md#python-test-modes)
for their invocation, reports, and environment gates.

Konflux onboarding must use the `linux-m2xlarge/*` builders and retain the
three Hermeto prefetch inputs: Cargo at `.` and `e2e/rust`, plus the locked
Python dependencies at `odh`:

```json
{
  "path": "odh",
  "type": "pip",
  "requirements_files": ["requirements.txt"],
  "binary": {
    "packages": ":all:",
    "arch": "x86_64,aarch64",
    "os": "linux",
    "py_version": 311,
    "py_impl": "cp"
  }
}
```

The image name is `odh-openshell-e2e`; Konflux automation generates the
Tekton YAML files.
Before merging, validate the local hermetic build on both `linux/amd64` and
`linux/arm64` using `PLATFORM` with `deploy/konflux/build-local.sh e2e-odh`.

## Dependency maintenance

MintMaker, the Konflux Renovate service, maintains the image inputs:

| Input | Source of truth | Updates |
|---|---|---|
| UBI base image | `FROM` lines in `deploy/docker/Dockerfile.konflux.e2e-odh` | Renovate tag and digest updates |
| `oc`, Helm, cargo-nextest, uv | `# renovate:`-annotated `ARG <TOOL>_VERSION` lines in the Dockerfile | Renovate updates the Dockerfile and `generic-fetcher.yaml` in one PR, without automerge |
| Rust | Digest-pinned `rust-rhel9` builder `FROM` line | Renovate tracks its tag and digest; updates require review and two-architecture hermetic builds |
| RPMs | `rpms.in.yaml` and `rpms.lock.yaml` | MintMaker lock file maintenance |
| Python test dependencies | `odh/requirements.in` and the hash-pinned `odh/requirements.txt` | Regenerate with the command in `requirements.in` |

Renovate cannot recompute the SHA-256 checksums in `generic-fetcher.yaml`,
so a tool update fails the hermetic build until they are refreshed. Download
both architectures and rewrite the checksums with:

```shell
deploy/konflux/e2e-odh/sync-generic-fetcher.py --update <uv|oc|helm|nextest>
```

The Dockerfile `ARG` versions are the source of truth for the artifact URLs
and filenames. Check that `generic-fetcher.yaml` matches them for both
architectures, without network access, with:

```shell
mise run konflux:e2e-odh:check-pins
```

A UBI base update can change the available RPM versions. Regenerate
`rpms.lock.yaml` with the command in `rpms.in.yaml` when the hermetic build
reports a missing package, or wait for the next lock file maintenance PR.
The uv version in the image is independent of the developer toolchain version
in `mise.toml`.
