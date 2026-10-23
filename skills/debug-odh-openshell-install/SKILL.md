---
name: debug-odh-openshell-install
description: Debug an ODH or RHOAI OpenShell gateway-and-dashboard installation made with the midstream installer in deploy/rhoai. Use for installer preflight failures, Helm release state for openshell and openshell-dashboard, installer state ConfigMap, dashboard OIDC Secret, shared gateway CA Secret, or Route admission. Use debug-openshell-cluster for gateway runtime, compute driver, and sandbox startup failures. Trigger keywords - ODH install, RHOAI install, openshell-dashboard, openshell-installer, dashboard OIDC, deploy/rhoai, installer preflight.
---

<!-- Midstream-only skill. Keep ODH installer guidance here instead of in
     skills/debug-openshell-cluster/SKILL.md so that file stays identical to
     upstream and the upstream sync merges it cleanly. -->

# Debug ODH OpenShell Installation

For an ODH gateway-and-dashboard installation, inspect both Helm releases
(`openshell` and `openshell-dashboard`) in the administrator-selected namespace
(`namespace` in the configuration or the `--namespace` override). Existing
namespaces do not need an installer ownership label. The installer
preserves partial installations and credentials on failure; gateway readiness
does not establish dashboard login or sandbox readiness. Check the
`openshell-installer` state ConfigMap, the dashboard OIDC Secret, the shared
gateway CA Secret, and admission of both Routes. A gateway chart under another
release name or an existing fixed release without installer state requires
explicit migration; do not change state to bypass these checks. Detection also
inspects stored Helm workloads for the `openshell-gateway` container or executable,
including failed and scaled-to-zero releases with renamed charts. Custom packaging
that removes both markers and workloads outside Helm require manual inspection.
A first installation requires a client-secret file matching any existing dashboard
OIDC Secret; only an installation with recorded state can omit the file.
For a new namespace, credential preflight checks local files without querying
namespaced objects before namespace creation. Earlier
installations used namespace annotations for state, which reruns migrate while
preserving namespace metadata. Use the published
[Kubernetes setup guide](https://docs.nvidia.com/openshell/latest/kubernetes/setup.md)
for the installation entry point. Diagnose Agent Sandbox availability separately;
the installer does not provision that controller or RHOAI itself.
Its read-only preflight checks storage, installation permissions, and recorded
OIDC identities across installer-managed namespaces. Distinct gateways need
distinct audiences and browser clients. Legacy state without OIDC metadata needs
manual review; retained history for another uninstalled release is not an active
gateway. Operational values files are reapplied on every upgrade; authentication,
TLS, naming, and namespace overrides are rejected. The deployment guide also
provides a read-only verifier for admin/ordinary-user workspace authorization;
it does not establish browser login, sandbox lifecycle, or network-policy enforcement.

For gateway runtime, compute platform, and sandbox startup failures after
installation, use the `debug-openshell-cluster` skill.
