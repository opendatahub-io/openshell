# ODH E2E Image Build

The ODH Konflux e2e image is a separate test artifact. Its
multi-stage UBI9 build compiles the CLI and a nextest archive from two
independent Cargo lockfiles on the Red Hat rust-builder image, with crates,
RPMs, and cluster tools prefetched by Hermeto for a network-isolated build. The runtime image carries the compiled
archive, Cargo and nextest executables, cluster tools, the SSH client needed
by sandbox lifecycle tests, and Git for repository workloads.

At runtime, the image entrypoint reads the fork-local tier plan, deploys each
phase's gateway mode through the shared Quay deployment script, runs the
phase-specific nextest selection from the precompiled archive, and tears down
that deployment before moving to the next phase. Local `mise run e2e:odh*`
tasks use the same plan, entrypoint, and deployment path. Tier 2, `odh`, and
`full` run shared mode followed by managed-workspace mode; each logical tier
runs image provenance once in the shared phase. The entrypoint preserves
cleanup on failures and signals, continues after a test-phase failure, and
merges the ordered JUnit files into one `e2e-odh-<tier>-xunit.xml` for Jenkins
discovery plus `e2e-odh-<tier>.html`. Phase reports remain available as
`e2e-odh-<tier>-<phase>.xml`. The no-deploy option is supported only for
single-phase tiers. Extracted client mTLS material is stored in a mode `0700`
directory with mode `0600` files. The runtime image owns its home and workspace
as UID/GID `1001:1001`, matching the Shift-Left pipeline's
`podman run --userns=keep-id --user 1001:1001`.

Each deployed invocation has a DNS-safe run ID. During the temporary upstream
managed-test compatibility period, the default namespace and Helm release are
both `openshell`; the gateway registration and Route host remain run-scoped.
Do not run ODH E2E invocations concurrently against the same cluster. Explicit
resource-name overrides remain exact. The entrypoint pins phase CLI commands to
that invocation's gateway and exports the run identity for follow-up test modes.

Gateway modes and tier phases are data in
`e2e/rust/tests/odh/tiers.toml`. Mode overlays are validated repository paths,
and the deploy script checks the deployed Helm values before the tests start.
Image repository, tag, and digest overrides can vary between local and image
runs; phase selection and gateway configuration come from the shared plan.
The entrypoint discovers digest-pinned runtime images from the installed
RHOAI/ODH operator CSV before deploying using a bash-only `discover_e2e_images`
function compatible with Bash 3.2 and later. It fetches the selected CSV's
deployment env vars and related images in one request. Discovery retries
transient query failures up to three attempts and stops before deployment
if a query still fails. Discovered images must come from the expected registry
(`registry.redhat.io/rhoai/` for RHOAI, `quay.io/opendatahub/` for ODH) and
match `^[a-z0-9._/-]+@sha256:[0-9a-f]{64}$`. Per-image environment overrides
take precedence. See [runtime image selection](../../../e2e/rust/tests/odh/README.md#runtime-image-selection)
for selection rules, permissions, and fallback behavior.

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

`sync-generic-fetcher.py` keeps the Dockerfile tool versions and the Hermeto
generic artifacts consistent. `--check` (offline) verifies that the URLs and
filenames derive from the Dockerfile versions and that checksums are
well-formed. `--update <tool>` recomputes checksums by downloading both
architectures concurrently, retrying transient failures and comparing each
hash with the publisher-provided checksum sidecar. This catches corruption or
inconsistent responses, but the sidecar is not an independent trust root
because it comes from the same origin as the artifact. Run it after a Renovate
bump, as the PR note instructs. Nothing is written unless every download
succeeds and matches its sidecar.
