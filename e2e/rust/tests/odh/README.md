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
│   ├── image_provenance.rs     # deployed-image provenance: requested digests vs running pods, registry allowlist, pull-policy check, JSON evidence
│   └── sandbox.rs              # sandbox create/exec/delete + supervisor presence check
├── tier1/                     # Tier 1: high-priority tests, excluding Smoke
│   ├── mod.rs
│   └── selinux.rs              # combined/sidecar process-supervisor SELinux label
├── tier2/                     # Tier 2: medium/low priority positive tests
│   ├── mod.rs
│   └── managed_identity.rs    # managed namespace UID/GID and process MCS isolation
├── tier3/                      # Tier 3: negative and destructive tests
│   └── mod.rs                    # empty — no scenarios yet
├── nextest.toml                # ODH profile and lifecycle serialization group
├── tiers.toml                  # data-only gateway modes and ordered tier phases
├── tier_plan.py                # validates modes, overlays, and test selectors
└── run-odh-test-tier.sh        # runs one resolved phase against its gateway
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
  OpenShift, checks every Ready worker's enforcement mode, records node-local
  audit cutoffs, and rejects OpenShell AVCs on completion. `begin()` requires
  enforcement; `begin_if_enforcing()` skips known non-enforcing modes. Both
  discover workers and check enforcement once, and fail on discovery/access errors.

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

`tiers.toml` keeps the familiar top-level tier tables. Shared is the default,
so each tier lists only its shared tests. A nested `[tier.managed]` table adds
the managed tests to that same tier; it does not create another tier. The
runner executes the base shared phase and then the managed extension:

```toml
[modes.shared]
expected_helm_values = { server = { drivers = { kubernetes = { workspaceMode = "shared" } } } }

[tier2]
upstream_tests = ["workspace_lifecycle"]
odh_filter = "tier2::"

[tier2.managed]
upstream_tests = ["workspace_namespace_managed"]
```

Smoke covers gateway reachability, sandbox lifecycle, and image provenance.
Tier 1 checks the process-supervisor SELinux label and its mapped upstream
tests. It excludes four sandbox lifecycle tests after intermittent OpenShift
failures: `canonical_main_disconnect_reconnect_replays_history_for_same_process`,
`canonical_main_exit_255_is_not_retried_as_transport_failure`,
`on_failure_policy_replaces_runtime_and_preserves_workspace`, and
`canonical_main_and_exec_receive_declared_environment`. Full still includes all four.
Tier 2 runs `workspace_lifecycle`, ODH Tier 2, and image provenance in
shared mode, then runs `workspace_namespace_managed` against a separate
managed-mode deployment. The `odh` and `full` tiers use the same shared then
managed split. Each managed phase also selects `tier2::managed_identity::`.
The shared phases exclude that prefix through `excluded_odh_filters`, so the
managed-only scenarios do not appear as passes without running isolation checks.
These validated prefix exclusions apply after all test selections are combined,
including Full's `all_binaries` selection.
Image provenance runs once in each tier's shared phase. Smoke
and Tier 1/3 use only shared mode. Add Rust scenarios by creating a `.rs` file
under the tier's directory and declaring it with a `mod` line in that tier's
`mod.rs`; add its selector to the corresponding tier table or mode extension.

To add a Helm-overlay mode, define its validated values paths and expected
deployed values under `[modes.<name>]`. Shared is implicit; add a named mode
table such as `[tier2.managed]` only when that tier needs mode-specific tests.
The resolver rejects unknown modes, unsafe overlay paths, invalid selectors,
and empty phases before any cluster change. Configuration is data-only; it
cannot run commands.

The phase runner loads the fork-only `nextest.toml` with `--tool-config-file`
alongside the unchanged upstream `.config/nextest.toml`. The tool config supplies
ODH defaults; repository configuration takes precedence.
The nextest `e2e-odh` profile runs the serial sandbox lifecycle tests and
`tier1::selinux` tests in one group with `max-threads = 1`, preserving
serialization across nextest's separate test processes. Tier 1 and Full
include the previously quarantined sandbox lifecycle tests.
The upstream managed-workspace tests currently hard-code gateway identity
assumptions, so the entrypoint temporarily defaults the gateway namespace and
Helm release to `openshell`. The
`managed_gateway_cannot_read_or_modify_workspace_secrets` test also checks
generic Secret access although the source Secret Role is restricted to named
Secrets. `managed_supervisor_reads_client_tls_from_its_bootstrap_secret` expects
a client certificate in the supervisor bootstrap Secret, while the driver
intentionally stages only the CA certificate. Both assertions are excluded
globally until corrected upstream. Do not run ODH E2E invocations concurrently
against the same cluster during this workaround.
`tiers.toml`'s root `[global_test_exclusions]` table keeps exact known upstream
failures out of every tier and gateway phase; remove an entry when its underlying
test failure is fixed.
Full runs every other feature-enabled binary in shared mode and excludes the
managed-only binary there. It also keeps the existing exact exclusions for
`initial_sparse_policy_is_acknowledged_as_loaded`,
`sandbox_reaches_localhost_without_proxy_environment`, and `port_forward_echo`.
Excluded tests do not appear as passes or skips in the JUnit report.

## Prerequisites

- An OpenShift cluster with ODH/RHOAI installed. The normal tier tasks deploy
  the selected runtime images and tear down each phase deployment.
- `oc` CLI authenticated to that cluster.
- Rust toolchain and `mise` installed.
- Python 3.11 or newer, `cargo-nextest`, and `xsltproc` installed for tiered
  runs and HTML reports.
- The local task builds `openshell-cli` when `OPENSHELL_BIN` is unset. Set
  `OPENSHELL_BIN` to use another CLI binary.

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
| `mise run e2e:odh` | All ODH-specific scenarios plus the managed-workspace binary, including image provenance |
| `mise run e2e:odh:full` | All upstream e2e + e2e-kubernetes + ODH tests (see caveat below), including image provenance |
| `mise run e2e:odh:smoke` | Smoke tier: mapped upstream tests + ODH `smoke::` (includes image provenance) |
| `mise run e2e:odh:tier1` | Tier 1: mapped upstream tests + ODH `tier1::` + image provenance |
| `mise run e2e:odh:tier2` | Tier 2: mapped upstream tests + ODH `tier2::` + supported Python gateway E2E + image provenance |
| `mise run e2e:odh:tier3` | Tier 3: mapped upstream tests + ODH `tier3::` + image provenance |
| `mise run e2e:odh:python` | Supported upstream Python gateway E2E in the shared OpenShift mode |
| `mise run e2e:odh:oidc` | Keycloak OIDC and workspace-authorization Python E2E with a per-run RHBK fixture |
| `cargo nextest run --config-file "$PWD/.config/nextest.toml" --tool-config-file "odh:$PWD/e2e/rust/tests/odh/nextest.toml" --profile e2e-odh --manifest-path e2e/rust/Cargo.toml --features e2e-odh --test odh -E 'test(=module::test_name)'` | A single ODH test function |

### Python gateway E2E

`e2e:odh:python` reuses the public ODH entrypoint: it deploys the shared
OpenShift gateway, imports the example provider profiles, runs upstream
`e2e/python`, and tears the deployment down. It writes the phase-scoped report
`e2e-odh-python-shared-python.xml` and merged `e2e-odh-python-xunit.xml` plus HTML
companion in `results/`. `odh/python-gates.toml` contains the exact tests that cannot run
on the current OpenShift lane (host-only fixtures, unrestricted egress, the
missing Python workload image, and the pending upstream deletion-timeout
decision). It does not run the Rust image-provenance check. Gate entries are
collection-validated so an upstream rename cannot
silently leave a stale exclusion. The phase also fails when the JUnit report
shows no executed test case, so a suite that skips every collected case cannot
report success. The Python tests also run as part of the tier2 shared phase,
riding the same gateway deployment.

The public `mise` tasks that include the Python runner (`e2e:odh:python` and
`e2e:odh:tier2`) provision `python:dev` first. If invoking
`odh/scripts/e2e-odh-entrypoint.sh` directly for one of those plan-backed
tiers, prepare that environment yourself with `mise run python:dev`; this is
intentional so the entrypoint fails before deploying when the test interpreter
is unavailable.

### Keycloak OIDC and workspace authorization

`mise run e2e:odh:oidc` runs the OIDC Python suites — the upstream
`e2e/python/oidc` plus fork-only coverage in
`odh/tests/oidc` (multi-user isolation, M2M client-credentials, and revocation
via Admin API) — against a real Keycloak
on the OpenShift cluster. It is a
single-phase tier over the shared gateway mode: the runner provisions a
per-run Red Hat build of Keycloak (RHBK) fixture, deploys the gateway with a
temporary OIDC values overlay (explicit issuer, `realm_access.roles` role
claim, `scope` scopes claim, mandatory audience, anonymous access disabled,
and the fixture CA mounted for issuer TLS), validates the Keycloak-issued
identities, runs the suites, and tears the fixture and the gateway down. The
phase report is `e2e-odh-oidc-shared-oidc.xml`, merged into
`e2e-odh-oidc-xunit.xml`. The downstream multi-user scenarios live in
`odh/tests/oidc` rather than the upstream suite so the fork carries no diff
in `e2e/python`; both directories run in one pytest invocation against the
same fixture.

The fixture is split into focused scripts under `odh/scripts/oidc-fixture/`
(`setup.sh`, `cleanup.sh`, `diagnostics.sh`, over the shared `common.sh`),
dispatched by `odh/scripts/odh-oidc-fixture.sh`. Run state is two files with
different contracts: `fixture.env` is the operational environment the ODH
entrypoint consumes (issuer, endpoint, CA material, values overlay), and
`state.env` is the fixture-private record of namespaces, resource names, and
the ownership label. Neither ever holds a credential: the database password
is generated in memory and passed to its Secret through a file descriptor, and
the TLS private keys are deleted as soon as the serving certificate is stored
in the cluster.

Prerequisites:

- The lane installs `rhbk-operator` through OLM in the run-scoped namespace
  when the Keycloak and KeycloakRealmImport CRDs are not already served. Set
  `OPENSHELL_E2E_RHBK_CHANNEL` to select another supported channel. An
  existing `OPENSHELL_E2E_RHBK_NAMESPACE` is treated as caller-owned and is
  never deleted; the default run-scoped namespace is owned by the lane.
- The kubeconfig needs permission to create the fixture resources (Secrets,
  ConfigMaps, Services, PVCs, Deployments, Routes, Keycloak,
  KeycloakRealmImports) in that namespace.
- The fixture reuses `scripts/keycloak-realm.json` in-memory: users `admin@test`,
  `user@test`, and `user-b@test` with per-run generated passwords, the
  `openshell-admin`/`openshell-user` realm roles, the `openshell-cli` and
  `openshell-ci` clients with a per-run client secret, and the `openshell:all`
  and per-resource scopes. On lanes that exercise revocation, the fixture
  also appends an ephemeral ``openshell-revocation-test`` confidential client
  and ``revocation@test`` user (with ``realm-management/manage-clients``
  via ``clientRoles`` for that disposable realm) — all in-memory, never
  written to the shared realm file.

```bash
umask 077
oc --kubeconfig ~/.kube/config config view --minify --flatten > kubeconfig
chmod 600 kubeconfig
KUBECONFIG="$PWD/kubeconfig" \
OPENSHELL_E2E_RHBK_NAMESPACE=<operator-namespace> \
GATEWAY_IMAGE=<repo>@sha256:<digest> \
SUPERVISOR_IMAGE=<repo>@sha256:<digest> \
SANDBOX_IMAGE=<repo>@sha256:<digest> \
mise run e2e:odh:oidc
```

Runtime images default to the installed operator CSV like every other tier.
Unlike the nextest-backed tiers, the OIDC lane deploys into a run-scoped
namespace and Helm release (`openshell-oidc-<run id>`), so concurrent OIDC
invocations cannot collide with each other or with the `openshell`
namespace other tiers use. The OIDC runner requires the generated OpenShift
Route endpoint and issuer explicitly (`OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT`,
`OPENSHELL_E2E_OIDC_ISSUER`); it never derives or falls back to a local
Docker endpoint. The normal Python lane keeps forcing
`OPENSHELL_E2E_OIDC=0`; only this lane sets `OPENSHELL_E2E_OIDC=1` and runs
the OIDC suites single-process.

The identity preflight runs between gateway readiness and the suites: it
requests one token per fixture user directly from the issuer, checks the
issuer, distinct subjects, realm roles, and scope claims, and also exercises
the scoped-token and `openshell-ci` client-credentials contracts (issuer,
``aud=openshell-cli``, distinct subject, ``openshell-user`` without
``openshell-admin``) the suites depend on, writing fingerprinted evidence to
`results/oidc-<run id>-identity.json`. Any failure there is reported as an
identity-provider failure, while gateway failures surface in the deployment
readiness probes and the authenticated administrator session used to import
provider profiles.

On failure the lane collects redacted, per-component diagnostics under
`results/oidc-<run id>-diagnostics/` — one directory each for Keycloak,
PostgreSQL, the gateway, supervisors, sandbox workloads, and the test run
(resources, events, pod logs, the pytest log, and the reports). Tokens,
credentials, and fixture identities are redacted from every retained
artifact, and the pytest output is captured and redacted next to the phase
report as `oidc-<run id>-pytest.log`. Diagnostics are collected before
async managed-namespace deletion so sandbox evidence is not lost while
it is gathered. Cleanup runs after both success and failure, deletes only
resources labelled with the run identifier, and verifies the deletions
completed; a cleanup failure never masks the original result. Set
`OPENSHELL_E2E_RETAIN_ON_FAILURE=1` to keep the fixture and its state
directory for diagnosis after a failure — no credential or private key is
retained either way.

The upstream Docker OIDC lane (`mise run e2e:oidc-python:docker`) remains
unchanged and runs the upstream suite. The downstream full-coverage lane is
`mise run e2e:odh:oidc:docker`; it adds the fork-only OIDC suite compatible
with the Docker fixture without modifying the shared upstream task. The
revocation scenario (`revocation@test` / ``openshell-revocation-test``) is
OpenShift-only (ephemeral client provisioned in the per-run RHBK realm) and
shows as `SKIPPED` on Docker — not a failure.

Example, running the Smoke tier against a real cluster:

```bash
umask 077
oc --kubeconfig ~/.kube/config config view --minify --flatten > kubeconfig
chmod 600 kubeconfig
ALLOWED_IMAGE_REGISTRY_PREFIXES="quay.io/opendatahub/,ghcr.io/astral-sh/" \
  mise run e2e:odh:smoke
```

`ALLOWED_IMAGE_REGISTRY_PREFIXES` is required by the image provenance test.
Runtime images default to the installed operator CSV; `IMAGE_TAG` is only
needed for bare repository overrides or fallback images without Git metadata
— see [Runtime image selection](#runtime-image-selection). For RHOAI images, use
`registry.redhat.io/,ghcr.io/astral-sh/` instead. The shared entrypoint
generates a DNS-safe `OPENSHELL_E2E_RUN_ID` for each deployed invocation unless
you provide one. The namespace and Helm release default to `openshell` for
both shared and managed phases to preserve managed-test compatibility; gateway
registration and Route host remain run-scoped. Do not run ODH E2E invocations
concurrently against the same cluster. Set `NAMESPACE`, `RELEASE`,
`GATEWAY_NAME`, or `ROUTE_HOST` to preserve an exact custom value. Managed tests
currently require the default `openshell` namespace and release.
`OPENSHELL_GATEWAY` is set for phase commands so they target that invocation's
gateway. Shared and managed phases in a tier reuse the same run identity and run
sequentially, with teardown between phases. The shared deployment script applies
the OpenShift SCC and Route/TLS overlays for local and image runs, then layers
the ODH overrides: `IfNotPresent` pull policies and disabled unauthenticated
dev access. User RPCs use mTLS authentication at the application layer; TLS
still permits certificate-less sandbox clients using bearer JWTs. The deploy
preflight checks that a certificate-less `ListSandboxes` RPC is rejected;
health endpoints such as `/readyz` remain unauthenticated.
Set `OPENSHELL_E2E_RUN_ID` explicitly when you need a reproducible run-scoped
name; valid values are 1–24 lowercase DNS-safe letters, digits, or hyphens,
starting and ending with a letter or digit.
Set `OPENSHELL_E2E_DEPLOY_GATEWAY=0` only to attach to a compatible existing
gateway; this option works only for single-phase tiers.

### Managed-workspace SCC identity qualification

The managed phase of Tier 2, ODH, and Full qualifies namespace identity
isolation on OpenShift. The Kubernetes driver creates managed namespaces
without copying gateway SCC annotations and waits for OpenShift to allocate
each namespace's own `openshift.io/sa.scc.uid-range`,
`openshift.io/sa.scc.supplemental-groups`, and `openshift.io/sa.scc.mcs`.
It resolves the sandbox UID and primary GID from that target namespace.
The qualification deployment must leave explicit sandbox UID/GID overrides unset.

The expected invariant is non-overlapping UID and group allocations between
two managed workspace namespaces. Sandbox container identities and running
workload identities must fall within their own namespace's allocations.
On enforcing OpenShift, actual workload and supervisor process MCS categories
must match their namespace allocation and differ between workspaces. Category
sets are compared dynamically; individual categories may overlap.

These tests create and clean up temporary workspaces, sandboxes, and their
managed namespaces. Cleanup waits for namespace deletion; access errors or a
two-minute timeout fail the test and leave fallback cleanup enabled.
They do not change SCCs, grants, or namespace allocations.
They require cluster-wide Sandbox reads for namespace discovery and reuse the
existing `oc` namespace-cleanup and node-debug permissions. Both tests skip outside
OpenShift or a managed phase; only the MCS test skips when SELinux is not
enforcing. Discovery, RBAC, malformed allocations, and missing process labels
are failures on an eligible environment.
The scenarios share the lifecycle serialization group and have a 15-minute
nextest timeout to allow cold starts and cleanup.
The phase runner exports `OPENSHELL_E2E_GATEWAY_MODE` from the resolved plan.
For a direct single-test invocation against an existing managed gateway, set
`OPENSHELL_E2E_GATEWAY_MODE=managed` explicitly.

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

`e2e-odh` activates the upstream `e2e-kubernetes`, `e2e`, and managed-workspace
features. The shared entrypoint reads the same tier plan locally and in the
image, deploying and running one phase at a time. `e2e:odh` runs all ODH
scenarios; `e2e:odh:full` runs all feature-enabled binaries except the
managed-only binary in its shared phase, followed by that binary in managed
mode. Phase JUnit files are named `e2e-odh-<tier>-<phase>.xml`; the entrypoint
merges them into `e2e-odh-<tier>-xunit.xml` for Jenkins discovery and
`e2e-odh-<tier>.html` in `results/`.

### Image provenance runs in every nextest-backed tier

`smoke::image_provenance::test_sandbox_gateway_supervisor_images` runs in the
shared phase of every nextest-backed tier. An empty phase fails instead of passing
with an empty report.

## Image provenance verification

`smoke::image_provenance::test_sandbox_gateway_supervisor_images` creates a
sandbox, then verifies the images actually running on the cluster:

- **The gateway pod** and the **supervisor companion pod** (the supervisor
  runs as its own pod created by the Kubernetes driver; the rendered gateway
  config is recorded as secondary evidence).
- **The sandbox pod**, including its bootstrap container and ephemeral
  containers.
- When the deployment pins components by digest, each observed pod must run
  **exactly the requested immutable reference**: the pod spec's image matches
  the requested `repo@sha256:…`, and the resolved `imageID` contains an
  immutable digest. For a multi-arch manifest list, the `imageID` may
  identify the node's architecture-specific sub-manifest rather than the
  requested index digest.
- Workload and remaining images are checked against the
  `ALLOWED_IMAGE_REGISTRY_PREFIXES` allowlist, and no container may regress
  away from `imagePullPolicy: IfNotPresent`.

The verified references are written to `results/e2e-odh-runtime-images.json`
(next to the JUnit reports, honoring `OPENSHELL_E2E_RESULTS_DIR`), recording
for each source the requested image, the resolved runtime `imageID`, and the
gateway-configured images. Runtime image digests are required E2E evidence:
failure to persist the evidence fails the test.

```bash
ALLOWED_IMAGE_REGISTRY_PREFIXES="quay.io/opendatahub/,ghcr.io/astral-sh/" \
  cargo test --manifest-path e2e/rust/Cargo.toml --features e2e-odh --test odh \
  -- smoke::image_provenance::
```

### Digest-pinning inputs

The deploy script accepts a digest for every component; the provenance test
verifies whichever are requested:

- `GATEWAY_IMAGE_DIGEST`, `SUPERVISOR_IMAGE_DIGEST`, and
  `SANDBOX_IMAGE_DIGEST` — pin the gateway, supervisor, and sandbox runtime
  images. Each may also be embedded inline in `GATEWAY_IMAGE`,
  `SUPERVISOR_IMAGE`, or `SANDBOX_IMAGE` as `repo@sha256:…`; an explicit
  `*_IMAGE_DIGEST` that conflicts with an inline digest fails the deployment
  before Helm runs.
- `WORKLOAD_IMAGE`, `WORKLOAD_IMAGE_TAG`, and `WORKLOAD_IMAGE_DIGEST` —
  optionally pin the default sandbox workload image. When unset, the
  deployment leaves the chart's default untouched (no `sandbox.image.*`
  values are set) and the workload is checked only against the registry
  allowlist.
- With no digest requested for a component, that component is checked only
  against the registry allowlist.

### Registry allowlist and pull policy

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
    other workload image selected by the deployment, e.g.
    `ghcr.io/astral-sh/` when the Python E2E workload fixture is used.

  A prefix without a trailing `/` is rejected outright, since it could
  otherwise match a lookalike host (e.g. `registry.redhat.io` would also
  match `registry.redhat.io.attacker.example/image`).
- For deployed runs, `NAMESPACE` and `RELEASE` default to `openshell` across
  shared and managed phases; this preserves managed-test compatibility.
  `GATEWAY_NAME` and `ROUTE_HOST` are run-scoped. Explicit values are used
  exactly as supplied; do not run concurrent invocations against the same
  cluster while using the default namespace and release.
- The `imagePullPolicy: IfNotPresent` check applies to every container,
  including the sandbox pod's. The shared Quay deployment script sets the
  gateway, supervisor, and sandbox pull policies to `IfNotPresent`; manually
  attached gateways must use the same values.
- Requires the `oc` CLI in PATH with a kubeconfig targeting the cluster (same
  as the rest of this suite). When `OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE` is set,
  all provenance queries use that context; otherwise they use the kubeconfig's
  current context.

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

The image accepts `smoke`, `tier1`, `tier2`, `tier3`, `odh`, `full`, or `python`
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
  --userns=keep-id --user 1001:1001 \
  -v /path/to/reports:/home/odh/openshell-e2e-odh/results:Z,U \
  -v /path/to/kubeconfig:/home/odh/openshell-e2e-odh/.kube/config:ro,Z \
  --env-file containerEnvFile \
  quay.io/opendatahub/odh-openshell-e2e:odh-stable smoke
```

The image runs as UID/GID `1001:1001` and owns `/home/odh`, including the
OpenShell CLI configuration directory. Keep the pipeline's `--user` setting
at `1001:1001` so gateway registration and client mTLS material can be written.

The entrypoint assigns each invocation a DNS-safe run ID. For compatibility
with managed-workspace tests, the namespace and release default to `openshell`
across both shared and managed phases; the gateway name and Route host are
run-scoped. Explicit `NAMESPACE`, `RELEASE`, `GATEWAY_NAME`, and `ROUTE_HOST`
values remain exact. Do not run concurrent invocations against the same cluster
with the default namespace and release. Concurrent invocations also need
separate `OPENSHELL_E2E_RESULTS_DIR` directories to keep their tier reports
isolated.
The entrypoint pins the phase CLI to that gateway, then deploys each declared
mode, runs that phase, and tears it down before starting the next phase; shared
and managed phases do not run in parallel. It calls teardown after deployment,
test, or signal failures, then continues to later phases after a test failure.
Managed mode creates the attachable `e2e-regcred` source Secret required by
managed image-pull Secret staging before installing the gateway.
The deploy script refuses to replace an existing namespace unless
`OPENSHELL_E2E_REPLACE_EXISTING=1` is set and the namespace has the
`openshell.nvidia.com/deployed-by=odh-e2e` label. Failed deployments are
cleaned up only when a state marker confirms this script created the
namespace. SIGTERM is forwarded through the phase runner before teardown.
Before a managed phase, the entrypoint snapshots namespaces labelled for the
test gateway. It removes only matching namespaces that were absent from that
snapshot, including after test failure or termination, before tearing down the
gateway namespace. This cleanup relies on the documented no-overlapping-runs
constraint until upstream managed tests support a run-specific gateway identity.
The kubeconfig must permit
namespace creation, Helm deployment, and the OpenShift operations used by
the tests. Set `OPENSHELL_E2E_DEPLOY_GATEWAY=0` only when a single-phase tier
uses an already deployed gateway configured for the CLI inside the container;
multi-phase tiers reject this option before cluster access.

The environment file must set `ALLOWED_IMAGE_REGISTRY_PREFIXES` for the
provenance test. Runtime image selection follows the same rules as local runs.
If cluster admission rewrites image registries, include the destination registry
prefixes in `ALLOWED_IMAGE_REGISTRY_PREFIXES` too. Include the test workload's
registry as well; the chart's current default uses `nvcr.io/nvidia/base/`.

By default, deployment uses the `quay.io/opendatahub/odh-openshell-*`
midstream repositories. Override `QUAY_NAMESPACE`, `GATEWAY_IMAGE`,
`SUPERVISOR_IMAGE`, or `SANDBOX_IMAGE` to test another repository. Bare
repositories inherit `IMAGE_TAG`; complete tagged or digest references do not
need it. In the test image, which has no Git branch metadata, set `IMAGE_TAG`
when using bare repositories. In a source checkout, an unset tag is derived
from the current branch (sanitized and truncated to 128 characters).
`GATEWAY_IMAGE_DIGEST`, `SUPERVISOR_IMAGE_DIGEST`, and
`SANDBOX_IMAGE_DIGEST` can pin components by digest. An inline
`repo@sha256:…` reference must agree with any explicit digest. The workload
can optionally be pinned with `WORKLOAD_IMAGE`, `WORKLOAD_IMAGE_TAG`, and
`WORKLOAD_IMAGE_DIGEST`. The provenance test verifies requested gateway,
supervisor, and sandbox runtime digests against running pods; it checks the
workload against the registry allowlist.

### Runtime image selection

Before deploying any phase, the shared entrypoint's `discover_e2e_images`
function detects RHOAI or ODH by listing operator ClusterServiceVersions
(CSVs) across namespaces. Discovery supports Bash 3.2 and later. After checking
the OLM API, it uses two `oc` calls: one jsonpath listing for
`namespace|name|phase|copiedFrom|reason`, then one fetch of the selected
CSV's deployment env vars and `spec.relatedImages`. It selects the single
`Succeeded` CSV named `rhods-operator.*` or `opendatahub-operator.*`,
ignoring OLM copies (`metadata.labels["olm.copiedFrom"]`) and
`status.reason == "Copied"`. It reads these environment variables from the
CSV's deployment containers, falling back to `spec.relatedImages` entries
when the env vars are absent:

| E2E override | CSV environment variable | relatedImages name |
|---|---|---|
| `GATEWAY_IMAGE` | `RELATED_IMAGE_ODH_OPENSHELL_GATEWAY_IMAGE` | `odh_openshell_gateway_image` |
| `SANDBOX_IMAGE` | `RELATED_IMAGE_ODH_OPENSHELL_SANDBOX_IMAGE` | `odh_openshell_sandbox_image` |
| `SUPERVISOR_IMAGE` | `RELATED_IMAGE_ODH_OPENSHELL_SUPERVISOR_IMAGE` | `odh_openshell_supervisor_image` |

Discovered references must be sha256-pinned
(`^[a-z0-9._/-]+@sha256:[0-9a-f]{64}$`) and must come from the expected
registry for the detected product:

- **RHOAI** (`rhods-operator.*`): `registry.redhat.io/rhoai/`
- **ODH** (`opendatahub-operator.*`): `quay.io/opendatahub/`

This registry allowlist prevents a rogue CSV from injecting images from an
unauthorized registry. The strict character class also rejects `,` and `=`,
preventing Helm `--set-string` injection.

Discovery preserves the full `registry/repository@sha256:...` references and
resolves them once for all phases in that invocation. It does not change the
CLI inside the test image. The kubeconfig must allow cluster API discovery
and listing `clusterserviceversions.operators.coreos.com` across namespaces.

Set any of the three override variables to replace that image; the remaining
images still come from the CSV. Setting all three bypasses CSV discovery,
including its permission requirements. For example, this environment file
replaces just the gateway:

```shell
GATEWAY_IMAGE=quay.io/my-team/odh-openshell-gateway:custom
ALLOWED_IMAGE_REGISTRY_PREFIXES=quay.io/my-team/,registry.redhat.io/,nvcr.io/nvidia/base/
```

Fully tagged or digest-pinned images need no `IMAGE_TAG`. Bare repositories
use `IMAGE_TAG`, falling back to a sanitized Git branch name when available.
`IMAGE_TAG` alone does not override CSV images. `GATEWAY_IMAGE_DIGEST` still
overrides the selected gateway digest.

If OLM is absent or no RHOAI/ODH operator CSV is installed, deployment keeps
the existing `quay.io/opendatahub/odh-openshell-*` defaults for unset images.
`QUAY_NAMESPACE` changes the namespace of those fallback repositories.
Query failures, multiple successful operator CSVs, or an installed operator
without a successful CSV stop the run before deployment. Missing, conflicting,
unpinned, or wrong-registry CSV images also stop the run unless that image
has an explicit override. `OPENSHELL_E2E_DEPLOY_GATEWAY=0` skips discovery.

Each discovery query has a 30-second request timeout. Transient API failures
(such as timeouts, throttling, and connection resets) receive up to three
attempts with 1-second and 2-second backoff. Authorization errors fail
immediately; exhausted retries stop the run before deployment.

Run the discovery and deployment contract tests without a cluster:

```shell
mise run test:odh-infra
```

The `ODH Infrastructure Contracts` workflow runs this task on Linux and macOS
for changes to the discovery and deployment scripts and their dependencies.
It checks the system Bash on each runner, including macOS Bash 3.2. To select
that shell locally, set `OPENSHELL_E2E_TEST_BASH=/bin/bash`.

`NAMESPACE`, `RELEASE`, `ROUTE_HOST`, and `GATEWAY_NAME` control the deployment
and are exact when set;
use distinct values across parallel invocations. The entrypoint exports
`OPENSHELL_E2E_RUN_ID` and the derived names so future Python test modes can
reuse the same invocation identity. The image writes
phase reports named `e2e-odh-<tier>-<phase>.xml`, then merges them into
`e2e-odh-<tier>-xunit.xml` and `e2e-odh-<tier>.html` in `results/`.
Missing phase reports are skipped, so reports from completed phases remain
available after a later deployment or preflight failure; the task still exits
with the failure status.

Konflux automation creates the Tekton YAML files for the e2e image.

## Rebase guidance

- **Fork-only paths:** this directory (`e2e/rust/tests/odh/`),
  `tasks/test-odh.toml`, the new e2e image files under
  `deploy/konflux/e2e-odh/`, `deploy/docker/`, and `odh/scripts/`.
- **Shared files:** the image adds to `deploy/konflux/build-local.sh` and
  `.dockerignore`. Keep ODH Nextest settings in this directory's `nextest.toml`
  and leave upstream `.config/nextest.toml` unchanged. Review these edits
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
