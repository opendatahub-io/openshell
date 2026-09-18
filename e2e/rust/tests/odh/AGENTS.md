# Agent Instructions — ODH Downstream E2E Tests

Scope: this file governs `e2e/rust/tests/odh/`. It layers on top of the
repository-root `AGENTS.md`. This file states the *rules* agents must follow;
`README.md` in this directory holds the *mechanics* and is authoritative.

## Required reading

Before adding or changing any test here, read `README.md` in this directory. It
is the source of truth for:

- the directory layout and how tiers map to test modules;
- `tiers.toml` (tier → upstream `[[test]]` binaries + ODH module filter);
- how to run each `mise run e2e:odh:*` task and the single-test invocation;
- the image-provenance check and its required env vars
  (`ALLOWED_IMAGE_REGISTRY_PREFIXES`, `NAMESPACE`, `RELEASE`, `SKIP_IMAGE_PROVENANCE`);
- the `KUBECONFIG` isolation gotcha for `mise` tasks;
- rebase guidance for keeping this fork-only directory additive against
  `NVIDIA/OpenShell`.

Follow `README.md` for these; do not restate or duplicate its content here — if
a rule and the README disagree, fix the drift rather than guessing.

## Fork-only, rebase-safe

- Everything under `e2e/rust/tests/odh/` and `tasks/test-odh.toml` is fork-only
  and must stay that way. Do not add fork-specific content to any upstream file.
- The only upstream file this work may touch is `e2e/rust/Cargo.toml`, and only
  via the two appended additive blocks (the `e2e-odh` feature and the `odh`
  `[[test]]` entry). Never edit the root `AGENTS.md` for ODH-specific rules —
  put them here instead.

## Commit messages

- Prefix the commit title of any downstream-only (fork carry) commit with
  `CARRY:` so it is identifiable when rebasing against `NVIDIA/OpenShell`.
- Keep the repository-root Conventional Commits format after the prefix, e.g.
  `CARRY: test(odh): add SELinux enforcing coverage`.
- Sign off every commit for DCO (`git commit --signoff`) and never reference AI
  agents in the message, per the root `AGENTS.md`.

## Write verification as Rust tests, not bash

- Implement test and verification logic as Rust tests in the tier modules
  (`smoke/`, `tier1/`, `tier2/`, `tier3/`). Do not add bespoke bash runners to
  carry verification logic.
- Shelling out to `oc`/`kubectl` from a test is fine and already established
  (see `smoke/image_provenance.rs`). Node-level checks such as
  `oc debug node ... chroot /host ausearch` work the same from Rust — put them
  in a shared helper (see below), not a shell script.
- Cluster/deployment setup (Helm values, in-cluster fixtures, proxies) is
  environment setup, not a test. Keep it out of test bodies and out of new
  runner scripts. Tests assume an already-deployed, working gateway.

## Shared helpers

- Fork-local shared test code lives in `e2e/rust/tests/odh/odh_harness/`,
  declared with `mod odh_harness;` in `main.rs` and used as
  `crate::odh_harness::...` from any tier. All ODH tests compile into the single
  `odh` test binary, so a module is enough — no new crate or workspace change.
- Put ODH-specific helpers here: the `oc` command builder (honoring
  `OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE`), node discovery, `getenforce`, and the
  AVC-audit guard. Do not duplicate helpers across tier files.
- Do not add ODH helpers to the upstream `e2e/rust/src/harness/`
  (`openshell_e2e::harness`) library — that is an upstream file tree and editing
  it breaks the fork-only, rebase-safe rule. Keep reusing it for generic,
  non-ODH helpers such as `openshell_e2e::harness::sandbox::SandboxGuard`.
- The name is `odh_harness` (not `harness`) so `use` statements never collide
  with the upstream `openshell_e2e::harness` module.

## Expose tests only through the existing tiered tasks

- Add tests by creating a `.rs` file under the right tier and a `mod` line in
  that tier's `mod.rs`, and map upstream binaries/filters in `tiers.toml`. Do
  not add new one-off `mise` tasks for individual test lanes.
- A small, fixed set of entry points (`e2e:odh:smoke|tier1|tier2|tier3`) is a
  hard requirement: the OpenShift AI Shift-Left testing pipeline consumes these
  standard tier tasks as quality gates. Bespoke deploy-and-run tasks with their
  own deploy semantics and host-access assumptions are hard to slot into those
  gates — keep the surface stable.

## Gate environment-specific tests, don't fork the task

- Tests that require a specific environment (OpenShift, SELinux enforcing, node
  debug access) must self-skip cleanly when that environment is absent, so the
  tier tasks stay usable on any deployed cluster. Detect the environment
  (e.g. `route.openshift.io` presence, `getenforce`) or gate on the documented
  env vars rather than creating a separate task.
- Document any RBAC or cluster prerequisites (e.g. `oc debug node` host access)
  in this directory's `README.md`.

## Keep tests hermetic and self-cleaning

- Use the shared harness (`openshell_e2e::harness::...`, e.g. `SandboxGuard`)
  and clean up every resource a test creates.
- Never hard-code values that vary per cluster/pod (e.g. SELinux MCS
  categories); assert on stable properties only.
