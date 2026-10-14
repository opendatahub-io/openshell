# ODH Downstream E2E Tests

Downstream-only integration tests for running OpenShell on OpenShift with
Open Data Hub (ODH) / OpenShift AI (RHOAI) workloads. These are complementary
to the upstream `e2e:kubernetes` suite: they cover ODH/RHOAI-specific
behavior that upstream does not, and do not duplicate upstream coverage.

This directory is fork-only and does not currently overlap upstream files.
The ODH feature and test binary are appended to `e2e/rust/Cargo.toml` in the
fork. The e2e image also changes shared build and documentation files; review
those changes after each upstream sync.

## Directory layout

```
e2e/rust/tests/odh/
├── README.md                  # this file
├── main.rs                    # crate root, declares helper + tier modules, gated on feature "e2e-odh"
├── odh_harness/               # fork-local shared test helpers (see "Shared test helpers")
│   ├── mod.rs
│   └── oc.rs                   # `oc` command builder (honors active kube context) + JSON runner
├── smoke/                     # Smoke tier: component-level critical tests
│   ├── mod.rs
│   ├── gateway.rs              # gateway reachability
│   ├── image_provenance.rs     # sandbox/gateway/supervisor image registry + pull-policy check
│   └── sandbox.rs              # sandbox create/exec/delete + supervisor presence check
├── tier1/                     # Tier 1: high-priority tests, excluding Smoke
│   ├── mod.rs
│   └── selinux.rs              # combined/sidecar process-supervisor SELinux label
├── tier2/                     # Tier 2: medium/low priority positive tests
│   └── mod.rs                    # empty — no scenarios yet
├── tier3/                      # Tier 3: negative and destructive tests
│   └── mod.rs                    # empty — no scenarios yet
├── tiers.toml                  # tier → upstream test binaries + ODH module filter
└── run-odh-test-tier.sh        # runs one tier against a deployed gateway
```

All ODH test functions compile into a single `odh` test binary
(`[[test]] name = "odh"` in `Cargo.toml`). Cargo generates test names that
include the full module path, e.g. `smoke::gateway::test_reachable`, which is
what enables tier-based nextest filters (`test(~smoke::)`, `test(~tier1::)`, ...).

Adding a new test area within a tier is just adding a `.rs` file and a `mod`
line in that tier's `mod.rs` — no file grows unbounded, and no other tier is
affected.

## Shared test helpers

Fork-local test code shared across tiers lives in `odh_harness/`, declared with
`mod odh_harness;` in `main.rs` and used as `crate::odh_harness::...` from any
tier module. Because all ODH tests compile into the single `odh` test binary, a
plain module is enough — no new crate and no workspace change.

- `odh_harness::oc` — the `oc` CLI helpers. `oc_command()` builds a
  `tokio::process::Command` for `oc`, injecting `--context` from
  `OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE` (exported by `e2e/with-kube-gateway.sh`)
  when it is set, so every ODH test targets the same cluster the upstream
  harness does. `oc_json()` runs a query and parses `-o json` output, panicking
  with a descriptive message on any failure.
- `odh_harness::selinux::SelinuxAudit` — an opt-in scenario guard that detects
  OpenShift, requires every Ready worker to report `Enforcing`, records
  node-local audit cutoffs, and rejects OpenShell AVCs on completion.

Put ODH-specific shared helpers here (the `oc` builder and node-level SELinux
checks), and reuse them rather than
duplicating logic across tier files. Two rules keep this rebase-safe:

- **Do not** add ODH helpers to the upstream harness library
  (`e2e/rust/src/harness/`, `openshell_e2e::harness`). That is an upstream file
  tree; editing it breaks the fork-only guarantee. Keep consuming it for
  generic, non-ODH helpers (e.g. `openshell_e2e::harness::sandbox::SandboxGuard`).
- The module is named `odh_harness` (not `harness`) precisely so `use`
  statements never collide with the upstream `openshell_e2e::harness`.

## Test tiers

| Tier | Description | Time target |
|---|---|---|
| Smoke | Component-level critical tests | 5 min or less |
| Tier 1 | High-priority tests, excluding Smoke | 15 min or less |
| Tier 2 | Medium/low priority positive tests | No limit |
| Tier 3 | Negative and destructive tests | No limit |
| ODH | All ODH tests | No limit |
| Full | Every feature-enabled upstream and ODH test, except listed exclusions | No limit |

`tiers.toml` maps each tier to upstream Cargo test binaries (explicit or
auto-discovered) and the ODH module filter that belong to it:

```toml
[smoke]
upstream_tests = []
odh_filter = "smoke::"
```

The upstream test assignments in `tiers.toml` are currently placeholders —
they should be revisited based on measured execution time and actual test
criticality, not just copied as-is.

Smoke covers gateway reachability, sandbox lifecycle, and image provenance.
Tier 1 checks the process-supervisor SELinux label and its mapped upstream
tests. Tier 2 and Tier 3 have no ODH scenarios yet; they run their mapped
upstream tests and the image provenance check. Add scenarios by creating a
`.rs` file under the tier's directory and declaring it with a `mod` line in
that tier's `mod.rs`.

The nextest `e2e-odh` profile runs the serial sandbox lifecycle tests and
`tier1::selinux` tests in one group with `max-threads = 1`, preserving
serialization across nextest's separate test processes. Tier 1 and Full
include the previously quarantined sandbox lifecycle tests.
Full applies its other exact upstream exclusions from
`[full.upstream_test_exclusions]`. Excluded tests do not appear as passes or
skips in the JUnit report.

## Prerequisites

- An OpenShift cluster with ODH/RHOAI installed, and the OpenShell gateway
  already deployed to it (via Helm or otherwise).
- `oc` CLI authenticated to that cluster.
- Rust toolchain and `mise` installed.
- Python 3.11 or newer, `cargo-nextest`, and `xsltproc` installed for tiered
  runs and HTML reports.
- The `openshell` CLI binary built (`cargo build -p openshell-cli`) and its
  active gateway pointed at the deployed OpenShell instance (`openshell
  gateway add ...` / `openshell gateway select ...`) — the harness shells out
  to this binary and relies on its persisted config, not on any env var.

### The `KUBECONFIG` gotcha

This repo's `mise.toml` sets `KUBECONFIG = "{{config_root}}/kubeconfig"` for
every `mise run` task — a worktree-local file, deliberately isolated from
your personal `~/.kube/config`, so automated e2e/dev tasks (which create,
tear down, and mutate cluster state) never accidentally act on whatever
context you happen to have active elsewhere. This means:

- `mise run e2e:odh:*` always reads cluster credentials from
  `<repo_root>/kubeconfig`, regardless of your shell's own `$KUBECONFIG` or
  `~/.kube/config`.
- If you're targeting an existing cluster (rather than the local k3d dev
  flow, which populates this file automatically), populate it yourself once:

  ```bash
  umask 077
  oc --kubeconfig ~/.kube/config config view --minify --flatten > kubeconfig
  chmod 600 kubeconfig
  ```

  (`--kubeconfig ~/.kube/config` is explicit on purpose — if mise's shell
  hook has already exported `KUBECONFIG` for this directory, an unqualified
  `oc config view` would read from the very file you're trying to create.
  The `umask`/`chmod` keep the flattened cluster credentials — an mTLS
  client cert and key — from being created group/world-readable.)

## How to run

| Command | What runs |
|---|---|
| `mise run e2e:odh` | All ODH-specific tests (all tiers, `odh` binary only), including image provenance |
| `mise run e2e:odh:full` | All upstream e2e + e2e-kubernetes + ODH tests (see caveat below), including image provenance |
| `mise run e2e:odh:smoke` | Smoke tier: mapped upstream tests + ODH `smoke::` (includes image provenance) |
| `mise run e2e:odh:tier1` | Tier 1: mapped upstream tests + ODH `tier1::` + image provenance |
| `mise run e2e:odh:tier2` | Tier 2: mapped upstream tests + ODH `tier2::` + image provenance |
| `mise run e2e:odh:tier3` | Tier 3: mapped upstream tests + ODH `tier3::` + image provenance |
| `cargo nextest run --manifest-path e2e/rust/Cargo.toml --features e2e-odh --test odh -E 'test(=module::test_name)'` | A single ODH test function |

Example, running the Smoke tier against a real cluster:

```bash
umask 077
oc --kubeconfig ~/.kube/config config view --minify --flatten > kubeconfig
chmod 600 kubeconfig
ALLOWED_IMAGE_REGISTRY_PREFIXES="quay.io/opendatahub/,nvcr.io/nvidia/base/,ghcr.io/astral-sh/" \
  mise run e2e:odh:smoke
```

`ALLOWED_IMAGE_REGISTRY_PREFIXES` is required by the image provenance test —
see below. For RHOAI images, use
`registry.redhat.io/,nvcr.io/nvidia/base/` instead. Set `NAMESPACE`/`RELEASE`
too if your deployment doesn't use the defaults (`openshell`/`openshell`).
The Quay deployment script sets
`sandbox.image.pullPolicy=IfNotPresent`; other deployments must
configure it themselves.

### SELinux-enforcing OCP validation

Tier 1 includes the SELinux checks when it runs against an OpenShift cluster.
The tests expect an already-deployed, working gateway. The named preflight
checks `getenforce` on every Ready worker. Each audited SELinux scenario uses
`SelinuxAudit`, which self-skips outside OpenShift, records node-local cutoffs,
and queries `ausearch -m AVC -x` through `oc debug node … chroot /host` after
the scenario.
The audit covers the gateway and both supervisor executable paths, and the
supervisor test checks the stable `container_t` type without hard-coding pod
MCS categories.

The runner requires permission to create debug pods and access the host through
`chroot /host`. Deployment-specific Helm values and proxy fixtures are owned by
the environment that deploys the gateway; tier1 does not create them. The
custom egress control is intentionally outside SELinux scope; egress behavior
remains covered by the existing proxy tests, and this tier does not create a
SELinux-specific proxy fixture.

### Why `e2e:odh` / `e2e:odh:full` run more than you might expect

`e2e-odh` activates the upstream `e2e-kubernetes` and `e2e` features.
`run-odh-test-tier.sh` selects tests with one nextest filter per tier.
`e2e:odh` selects the `odh` binary; `e2e:odh:full` selects every test binary
enabled by those features. Both produce JUnit XML and HTML in `results/`.

### Every `e2e:odh*` task runs the image provenance check

`smoke::image_provenance::test_sandbox_gateway_supervisor_images` is a
regular test in the `odh` binary. The smoke, ODH, and full filters include it.
Tier 1–3 filters include it alongside their assigned tests so one nextest run
and one JUnit report cover the whole tier. `SKIP_IMAGE_PROVENANCE=1` excludes
it from Tier 1–3 when a local deployment cannot meet the image requirements.
An empty tier fails instead of passing with an empty report. Tier 3 currently
has no scenarios, so skipping image provenance makes it fail.

## Image provenance verification

`smoke::image_provenance::test_sandbox_gateway_supervisor_images` creates a
sandbox, then verifies the gateway pod, sandbox runtime bootstrap init
container, and supervisor companion pod all came from an authorized registry,
and that no container — including ephemeral containers — has regressed away
from `imagePullPolicy: IfNotPresent`.

```bash
ALLOWED_IMAGE_REGISTRY_PREFIXES="quay.io/opendatahub/,nvcr.io/nvidia/base/,ghcr.io/astral-sh/" \
  cargo test --manifest-path e2e/rust/Cargo.toml --features e2e-odh --test odh \
  -- smoke::image_provenance::
```

- `ALLOWED_IMAGE_REGISTRY_PREFIXES` (required, comma-separated, each prefix
  must end in `/`) — no default, since an empty list would silently approve
  any image. This should include every registry prefix your deployment
  legitimately pulls from:
  - `quay.io/opendatahub/` — the Quay deployment script's default repository
    namespace for the midstream gateway, supervisor, and sandbox runtime
    images.
  - `registry.redhat.io/` — RHOAI component images.
  - `nvcr.io/nvidia/base/` — the Helm chart's current default workload
    image (`server.sandboxImage`). Include the registry prefix for any
    other workload image selected by the deployment.
  - `ghcr.io/astral-sh/` — the ODH E2E harness's default tool-capable
    workload fixture (`uv`) when a test does not select another workload.

  A prefix without a trailing `/` is rejected outright, since it could
  otherwise match a lookalike host (e.g. `registry.redhat.io` would also
  match `registry.redhat.io.attacker.example/image`).
- `NAMESPACE`/`RELEASE` env vars default to `openshell`/`openshell`.
- The check is a registry-prefix allowlist, not an exact image/digest match.
  It checks each observed image against the configured allowed prefixes.
  The rendered sandbox runtime image is checked too when the deployment
  overrides it.
- When the deployment pins an image by digest, through `GATEWAY_IMAGE_DIGEST`,
  `SUPERVISOR_IMAGE_DIGEST`, `SANDBOX_IMAGE_DIGEST`, or a `repo@sha256:...`
  reference in the equivalent image override, the test also requires the
  corresponding running container to retain that exact immutable reference
  and to report a resolved `imageID`: the gateway container, the supervisor
  companion container, and the sandbox bootstrap init container. A resolved
  ID can be the platform-specific manifest selected from a multi-architecture
  index, so it need not be identical to the requested index digest. A rendered
  value or Pod spec without a resolved ID is not sufficient. This catches
  nodes running stale mutable-tag caches.
  Images without a digest keep the allowlist-only behavior.
- Every verified reference, with the resolved `imageID` reported by each pod,
  is written to `results/e2e-odh-runtime-images.json` as run evidence.
- The `imagePullPolicy: IfNotPresent` check applies to every container,
  including the sandbox pod's. The Quay deployment script sets
  `sandbox.image.pullPolicy=IfNotPresent`; other deployments must set it
  explicitly.
- Requires the `oc` CLI in PATH with a kubeconfig targeting the cluster (same
  as the rest of this suite). When `OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE` is set,
  all provenance queries use that context; otherwise they use the kubeconfig's
  current context.
- Skip it locally with `SKIP_IMAGE_PROVENANCE=1 mise run e2e:odh:tier1` when
  testing a local deployment. Smoke, ODH, and full always include it.

## E2E container image

The Konflux `odh-openshell-e2e` image builds the OpenShell CLI and the
`e2e-odh` nextest archive from this checkout. It includes `cargo`,
`cargo-nextest`, `oc`, `kubectl`, Helm, Python 3.11, `xsltproc`, Git, and the SSH
client used by sandbox lifecycle tests.
See [the ODH image build overview](../../../../deploy/konflux/e2e-odh/README.md)
for its build and runtime boundaries.
The image is built for x86_64 and aarch64 from pinned Cargo, RPM, and generic
artifacts. On Linux with Hermeto, `rpm`, and Podman installed, build it
locally with:

```shell
./deploy/konflux/build-local.sh e2e-odh
```

The local build tags the image as `odh-openshell-e2e`.

The image accepts `smoke`, `tier1`, `tier2`, `tier3`, `odh`, or `full`
as its first argument; `smoke` is the default. The Shift-Left job mounts
cluster credentials and a writable report directory, then passes environment
variables through `--env-file`:

```shell
# Login to the cluster storing the kubeconfig file in the current folder
oc login --token=XXXXXX \
--server=https://api.example.com:443 \
--kubeconfig $PWD/kubeconfig

# Run the e2e tests
podman run --rm \
  -v /path/to/reports:/home/odh/openshell-e2e-odh/results:Z,U \
  -v /path/to/kubeconfig:/home/odh/openshell-e2e-odh/.kube/config:ro,Z \
  --env-file containerEnvFile \
  quay.io/opendatahub/odh-openshell-e2e:odh-stable smoke
```

By default, the entrypoint calls
`odh/scripts/openshell-deploy-from-quay.sh deploy --yes`, runs the tier,
then calls `teardown --yes` even if tests fail. The deploy script refuses to
replace an existing namespace unless
`OPENSHELL_E2E_REPLACE_EXISTING=1` is set and the namespace has the
`openshell.nvidia.com/deployed-by=odh-e2e` label. Failed deployments are
cleaned up after namespace creation; validation failures preserve local
gateway registration. SIGTERM is forwarded to nextest before teardown.
The kubeconfig must permit
namespace creation, Helm deployment, and the OpenShift operations used by
the tests. Set `OPENSHELL_E2E_DEPLOY_GATEWAY=0` only when a gateway is
already deployed and configured for the CLI inside the container.

The environment file must set `IMAGE_TAG` for the gateway, supervisor,
and sandbox images, plus `ALLOWED_IMAGE_REGISTRY_PREFIXES` for the
provenance test. By default, the deployment uses the
`quay.io/opendatahub/odh-openshell-*` midstream repositories.
Override `QUAY_NAMESPACE`, `GATEWAY_IMAGE`, `SUPERVISOR_IMAGE`, or
`SANDBOX_IMAGE` when testing another repository. Set the corresponding
`*_IMAGE_DIGEST` variable to pin it immutably. `NAMESPACE`, `RELEASE`,
`ROUTE_HOST`, and `GATEWAY_NAME` control the deployment. The image writes
`e2e-odh-<tier>.xml` and
`e2e-odh-<tier>.html` to `results/`. Set
`OPENSHELL_E2E_REPORT_NAME` to choose another basename. The JUnit report
is produced by one nextest invocation per tier.

Konflux automation creates the Tekton YAML files for the e2e image.

## Python test modes

`odh/scripts/run-odh-python-tests.sh` is the focused Python test runner. It
takes one mode and writes its own JUnit report with an HTML companion to
`results/` (or `OPENSHELL_E2E_RESULTS_DIR`). The runner itself never deploys
or tears down a gateway. The image's standard
`odh/scripts/e2e-odh-entrypoint.sh` entrypoint dispatches to it, so
`gateway-e2e` uses the same deploy, provider-profile import, and teardown
lifecycle as the Rust tiers.

| Mode | What runs | Cluster | Report |
|---|---|---|---|
| `sdk` | Python SDK unit tests in `python/openshell/`, excluding the `gpu` marker | Not required | `e2e-odh-python-sdk.xml` |
| `gateway-e2e` | `e2e/python` with `pytest-xdist` (`E2E_PARALLEL`, default 5) | Deployed and selected gateway | `e2e-odh-python-gateway-e2e.xml` |

`gateway-e2e` resolves the gateway the same way the CLI does: from
`OPENSHELL_GATEWAY`, or else the active gateway. It fails before running
pytest when neither is set. Both modes propagate test failures, fail when no
tests are selected or no JUnit report is written, and forward SIGINT and
SIGTERM to pytest. The `sdk` mode leaves out tests that check packaging and
local gateway fixtures rather than the SDK, and that read repository files the
image does not carry: `python/release_tooling_test.py`,
`python/wheel_verifier_test.py`, and, under `python/openshell/`,
`release_formula_test.py`, `rpm_gateway_config_migration_test.py`, and
`gateway_config_fixture_test.py`. The image carries the `sdk/conformance/`
fixtures that the SDK tests read.

Run the modes locally with:

```shell
mise run e2e:odh:python:sdk
mise run e2e:odh:python:gateway
```

The image carries a prefetched Python environment and generated protobuf
bindings, so both modes run without network access to package indexes. Use the
image's normal entrypoint; do not override it with the internal Python runner:

```shell
podman run --rm \
  -v /path/to/reports:/home/odh/openshell-e2e-odh/results:Z,U \
  quay.io/opendatahub/odh-openshell-e2e:odh-stable sdk
```

For `gateway-e2e`, pass the same `KUBECONFIG`, image references, and deployment
variables as the Rust `odh` mode. The entrypoint deploys the gateway, imports
the example provider profiles, runs the Python suite, and tears the deployment
down. Set `OPENSHELL_E2E_DEPLOY_GATEWAY=0` only when a compatible gateway is
already deployed and selected locally.

The default ODH sandbox workload is intentionally unchanged. To test a
Python-capable workload without changing gateway, supervisor, or sandbox runtime
images, set `WORKLOAD_IMAGE` and pin it with `WORKLOAD_IMAGE_DIGEST`; the deploy
script maps those values only to Helm's `sandbox.image`. For example, an OCP
cluster authorized to pull the image can use
`registry.redhat.io/ubi9/python-312`. This supplies Python itself, but not the
upstream workload's extra libraries or `/sandbox/.venv`; retain explicit gates
for tests that require those capabilities.

### Environment gates

Some upstream `e2e/python` tests assume the local Docker gateway. The
`gateway-e2e` mode loads `odh/scripts/pytest_odh_gates.py`, which reports the
tests listed in `odh/python-gates.toml` as skipped with their category and
reason, so unsupported coverage never appears as a pass. Upstream test files
are not edited.

| Category | Tests | Reason |
|---|---|---|
| `docker-host` | `test_sandbox_providers.py`: the OpenAI and Anthropic native-endpoint tests | The fake endpoint listens on the test host behind `host.openshell.internal` |
| `egress` | `test_sandbox_venv.py`: pip, `uv pip`, and `uv run` installs; `test_sandbox_providers.py`: GitHub clone | Downstream CI clusters do not guarantee egress to PyPI or GitHub |
| `workload-image` | `test_sandbox_providers.py::test_google_metadata_sdk_discovery` | Requires packages that only `e2e/python/Dockerfile.workload` provides |

The OIDC tests under `e2e/python/oidc/` keep their upstream
`OPENSHELL_E2E_OIDC` gate and belong to the ODH OIDC lane. GPU tests are
deselected with `-m "not gpu"`, as in upstream; no `e2e/python` test currently
carries that marker.

Gates list exact node IDs without parametrization. Before running tests, the
runner validates the list in a serial collection-only pass, so a gated test
that no longer exists fails the mode with exit code 2; remove its entry when
upstream renames or deletes it. Remove a gate once its test can run on
OpenShift.

## Rebase guidance

- **Fork-only paths:** this directory (`e2e/rust/tests/odh/`),
  `tasks/test-odh.toml`, the new e2e image files under
  `deploy/konflux/e2e-odh/`, `deploy/docker/`, and `odh/`. The e2e image
  Renovate managers live in the fork-only `renovate.json`.
- **Shared files:** the image adds to `.config/nextest.toml`,
  `deploy/konflux/build-local.sh`, and `.dockerignore`. Review these edits
  whenever upstream changes those files. The fork also carries the
  `e2e-odh` feature and `odh` test entry in `e2e/rust/Cargo.toml`; preserve
  those entries when syncing upstream changes to that file.
- **Shared harness dependency:** ODH tests use the upstream test harness
  library (`e2e/rust/src/`, e.g. `openshell_e2e::harness::binary::openshell_cmd`,
  `openshell_e2e::harness::sandbox::SandboxGuard`). If upstream changes those
  signatures, the ODH test modules need the same adaptation during rebase.
- **Upstream test inventory changes:** if upstream adds, removes, or renames
  `[[test]]` binaries, update the `upstream_tests` lists in `tiers.toml`
  accordingly.
- If upstream adds OpenShift auto-detection to `e2e:kubernetes`, this suite
  stays additive — it exercises ODH/RHOAI-specific behavior beyond what
  upstream covers, and `e2e-odh`'s dependency on `e2e-kubernetes` means
  upstream harness improvements propagate automatically.
