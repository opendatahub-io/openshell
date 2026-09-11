# ODH Downstream E2E Tests

Downstream-only integration tests for running OpenShell on OpenShift with
Open Data Hub (ODH) / OpenShift AI (RHOAI) workloads. These are complementary
to the upstream `e2e:kubernetes` suite: they cover ODH/RHOAI-specific
behavior that upstream does not, and do not duplicate upstream coverage.

This directory is fork-only — none of it exists upstream, and none of it will
conflict on a rebase against `NVIDIA/OpenShell`. The only upstream file
touched by this work is `e2e/rust/Cargo.toml`, and that change is purely
additive (a new feature flag and a new `[[test]]` entry, both appended).

## Directory layout

```
e2e/rust/tests/odh/
├── README.md                  # this file
├── main.rs                    # crate root, declares tier modules, gated on feature "e2e-odh"
├── smoke/                     # Smoke tier: component-level critical tests
│   ├── mod.rs
│   ├── gateway.rs              # gateway reachability
│   ├── image_provenance.rs     # sandbox/gateway/supervisor image registry + pull-policy check
│   └── sandbox.rs              # sandbox create/exec/delete + supervisor presence check
├── tier1/                     # Tier 1: high-priority tests, excluding Smoke
│   └── mod.rs                    # empty — no scenarios yet
├── tier2/                     # Tier 2: medium/low priority positive tests
│   └── mod.rs                    # empty — no scenarios yet
├── tier3/                      # Tier 3: negative and destructive tests
│   └── mod.rs                    # empty — no scenarios yet
├── tiers.toml                  # tier → upstream test binaries + ODH module filter
└── run-odh-test-tier.sh        # runner: entrypoint for tiered execution
```

All ODH test functions compile into a single `odh` test binary
(`[[test]] name = "odh"` in `Cargo.toml`). Cargo generates test names that
include the full module path, e.g. `smoke::gateway::test_reachable`, which is
what enables tier-based filtering (`-- smoke::`, `-- tier1::`, ...).

Adding a new test area within a tier is just adding a `.rs` file and a `mod`
line in that tier's `mod.rs` — no file grows unbounded, and no other tier is
affected.

## Test tiers

| Tier | Description | Time target |
|---|---|---|
| Smoke | Component-level critical tests | 5 min or less |
| Tier 1 | High-priority tests, excluding Smoke | 15 min or less |
| Tier 2 | Medium/low priority positive tests | No limit |
| Tier 3 | Negative and destructive tests | No limit |

`tiers.toml` maps each tier to the upstream `[[test]]` binaries (from
`e2e/rust/Cargo.toml`) and the ODH module filter that belong to it:

```toml
[smoke]
upstream_tests = []
odh_filter = "smoke::"
```

The upstream test assignments in `tiers.toml` are currently placeholders —
they should be revisited based on measured execution time and actual test
criticality, not just copied as-is.

**Current implementation status:** only the Smoke tier has real test
functions (`smoke::gateway::test_reachable`, `smoke::sandbox::test_create_delete`,
`smoke::image_provenance::test_sandbox_gateway_supervisor_images`).
Tier 1–3 are empty modules with no scenarios yet — running those tiers today
executes 0 ODH tests (a legitimate `ok` result, not a failure) plus whatever
upstream tests are mapped to them, plus the image provenance test (see
below). Add scenarios by creating a `.rs` file under the tier's directory and
declaring it with a `mod` line in that tier's `mod.rs`.

## Prerequisites

- An OpenShift cluster with ODH/RHOAI installed, and the OpenShell gateway
  already deployed to it (via Helm or otherwise).
- `oc` CLI authenticated to that cluster.
- Rust toolchain and `mise` installed.
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
| `cargo test --manifest-path e2e/rust/Cargo.toml --features e2e-odh --test odh -- test_name --exact` | A single ODH test function |

Example, running the Smoke tier against a real cluster:

```bash
umask 077
oc --kubeconfig ~/.kube/config config view --minify --flatten > kubeconfig
chmod 600 kubeconfig
ALLOWED_IMAGE_REGISTRY_PREFIXES="quay.io/opendatahub/,ghcr.io/nvidia/openshell-community/sandboxes/" \
  mise run e2e:odh:smoke
```

`ALLOWED_IMAGE_REGISTRY_PREFIXES` is required by the image provenance test —
see below. Set `NAMESPACE`/`RELEASE` too if your deployment doesn't use the
defaults (`openshell`/`openshell`). The Helm chart's
`server.sandboxImagePullPolicy` must also be set to `IfNotPresent` (it
defaults to `""`, i.e. Kubernetes' own default of `Always` for the
`:latest`-tagged sandbox image) — see below.

### Why `e2e:odh` / `e2e:odh:full` run more than you might expect

`e2e-odh` is defined as `e2e-odh = ["e2e-kubernetes"]` in `Cargo.toml`, so it
transitively activates the full upstream feature chain
(`e2e-odh` → `e2e-kubernetes` → `e2e`). Without a `--test` filter, `cargo
test --features e2e-odh` builds and runs **every** test binary whose
`required-features` are satisfied by that chain — not just the `odh` binary.
`e2e:odh` passes `--test odh` specifically to restrict to just the ODH
binary; `e2e:odh:full` intentionally omits that filter to run everything.

### Every `e2e:odh*` task runs the image provenance check

`smoke::image_provenance::test_sandbox_gateway_supervisor_images` is a
regular test in the `odh` binary, so it runs automatically whenever that
binary runs unfiltered: `e2e:odh` (`--test odh`, no substring filter) and
`e2e:odh:full` (no `--test` filter at all) both include it for free, with no
special wrapper needed — a passing test run can't mask a provenance failure,
since it's not a separate step to skip or short-circuit. The tiered tasks
(`e2e:odh:tier1`/`tier2`/`tier3`) go through `run-odh-test-tier.sh`, which
runs it explicitly as an extra step after the tier's own filter, since image
provenance is a property of the deployment, not of any one tier;
`e2e:odh:smoke` doesn't need that extra step since its own `smoke::` filter
already covers it.

## Image provenance verification

`smoke::image_provenance::test_sandbox_gateway_supervisor_images` creates a
sandbox, then verifies that its image, the gateway's image, and the
supervisor image (read from the rendered gateway config, since the
supervisor never runs as its own pod) all came from an authorized downstream
registry, and that no container — including ephemeral containers — has
regressed away from `imagePullPolicy: IfNotPresent`.

```bash
ALLOWED_IMAGE_REGISTRY_PREFIXES="quay.io/opendatahub/,ghcr.io/nvidia/openshell-community/sandboxes/" \
  cargo test --manifest-path e2e/rust/Cargo.toml --features e2e-odh --test odh \
  -- smoke::image_provenance::
```

- `ALLOWED_IMAGE_REGISTRY_PREFIXES` (required, comma-separated, each prefix
  must end in `/`) — no default, since an empty list would silently approve
  any image. This should include every registry prefix your deployment
  legitimately pulls from:
  - `quay.io/opendatahub/` — confirmed in practice for this project's
    gateway/supervisor/CLI builds.
  - `ghcr.io/nvidia/openshell-community/sandboxes/` — the sandbox default
    image (`server.sandboxImage` in the Helm chart). There is no
    downstream-built sandbox base image yet (only `gateway`, `supervisor`,
    and `cli` have Tekton pipelines under `.tekton/`), so this upstream
    prefix has to stay allowed until one exists. This is a different path
    than the upstream gateway/CLI images
    (`ghcr.io/nvidia/openshell/*`), which this check is meant to reject.

  A prefix without a trailing `/` is rejected outright, since it could
  otherwise match a lookalike host (e.g. `registry.redhat.io` would also
  match `registry.redhat.io.attacker.example/image`).
- `NAMESPACE`/`RELEASE` env vars default to `openshell`/`openshell`.
- The check is a registry-prefix allowlist, not an exact image/digest match.
  It works because the downstream pipeline only ever publishes to one
  registry — matching that prefix is sufficient proof an image (including
  the supervisor) is the downstream build and not an upstream
  `ghcr.io/nvidia/openshell/*` reference.
- The `imagePullPolicy: IfNotPresent` check applies to every container,
  including the sandbox pod's. The Helm chart's `server.sandboxImagePullPolicy`
  defaults to `""` (Kubernetes' own default, which is `Always` for a
  `:latest`-tagged image like the default sandbox image) — deployments must
  set it explicitly, e.g. `--set server.sandboxImagePullPolicy=IfNotPresent`,
  or this check fails on a freshly installed chart.
- Requires the `oc` CLI in PATH with a kubeconfig targeting the cluster (same
  as the rest of this suite).
- Skip it locally with `SKIP_IMAGE_PROVENANCE=1 mise run e2e:odh:tier1` (e.g.
  if `oc` isn't configured for the target cluster in your current shell) —
  this only affects the tiered tasks' extra step; `e2e:odh`/`e2e:odh:full`/
  `e2e:odh:smoke` always include it since it's just another test in scope.

## Rebase guidance

- **Fork-only, no conflict risk:** everything in this directory
  (`e2e/rust/tests/odh/`), plus `tasks/test-odh.toml`.
- **Touches upstream:** only `e2e/rust/Cargo.toml`, and only via two
  appended blocks (the `e2e-odh` feature line, and the `[[test]]` entry for
  the `odh` binary). If upstream changes this file and a rebase conflicts,
  resolution is mechanical: re-append both blocks at the end of their
  respective sections.
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
