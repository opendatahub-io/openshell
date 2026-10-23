# ODH Gateway and Dashboard Troubleshooting

For an ODH gateway-and-dashboard installation, inspect both Helm releases
(`openshell` and `openshell-dashboard`) in the administrator-selected namespace
(`namespace` in the configuration or the `--namespace` override). Existing
namespaces do not need an installer ownership label. The installer
preserves partial installations and credentials on failure; gateway readiness
does not establish dashboard login or sandbox readiness. Check the
`openshell-installer` state ConfigMap, the dashboard OIDC Secret, the shared
gateway CA Secret, and admission of both Routes for their configured hostnames.
Admission for a previous hostname does not establish readiness. A gateway chart
under another release name or an existing fixed release without installer state requires
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
Its read-only preflight checks storage, installation permissions (including
`update secrets` and `delete secrets` for Helm release storage and history
pruning), and recorded OIDC identities across
installer-managed namespaces. Distinct gateways need
distinct audiences and browser clients. Installation rechecks conflicts after
publishing its identity reservation and before Helm activation. Conflicting
reservations remain for diagnosis. Legacy state updates preserve recorded fields
and stop on a resource-version conflict; inspect the state before retrying.
Legacy state without OIDC metadata needs manual review; retained history for
another uninstalled release is not an active
gateway. Operational values files are reapplied on every upgrade; authentication,
TLS, naming, and namespace overrides are rejected. The deployment guide also
provides a read-only verifier for admin/ordinary-user workspace authorization;
it does not establish browser login, sandbox lifecycle, or network-policy enforcement.
The other-gateway token check requires HTTP 401. HTTP 403 can mean the token
authenticated but lacks a required role, so it does not prove audience isolation.
