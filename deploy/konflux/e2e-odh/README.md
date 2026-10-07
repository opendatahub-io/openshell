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
generated protobuf bindings, so later named Python test modes can execute
without runtime dependency downloads.

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
