# OpenShell and Dashboard installer for OpenShift

This ODH-fork installer installs two independent Helm releases, `openshell` and
`openshell-dashboard`, into the administrator-selected namespace. It reuses an
existing namespace or creates it if missing. Each namespace has one gateway and
its dashboard; reruns upgrade the same releases. The gateway chart supplies
the gateway and the configuration for launching supervisor and sandbox workloads.
The UI chart remains in the [dashboard repository](https://github.com/opendatahub-io/openshell-dashboard/tree/main/deploy/helm/openshell-dashboard).

This is an initial installer, not a qualified RHOAI deployment. Gateway chart
`0.1.3` and dashboard chart `0.1.0`, using their default images, passed the live
smoke checks below on OpenShift `4.21.8`. Matching `0.1` release lines alone do
not prove API compatibility. Choose exact published versions and validate them
together. The script intentionally has no default release versions. Exact SemVer
prereleases such as `0.0.0-dev.<commit>` are accepted for downstream builds;
accepting a version does not establish chart or image compatibility.

## Live validation

On October 13, 2026, the installer was exercised on an OpenShift `4.21.8` cluster
with RHOAI installed, OVN Kubernetes, `gp3-csi` storage, Agent Sandbox `v1.0.6`, and
an existing Red Hat build of Keycloak `26.4.10`. A dedicated test realm supplied
OIDC; existing customer realms were not changed.

The following checks passed with gateway chart `0.1.3` and dashboard chart `0.1.0`:

- First installation into a new namespace and a second run with the same inputs.
- Installation and rerun in a separately pre-created namespace selected with
  `--namespace`, with both releases reaching revision 2 and the namespace's labels,
  annotations, and OpenShift SCC allocations preserved.
- Gateway readiness, both dashboard containers ready, and persistent storage bound.
- Public HTTPS routing and HTTP 401 for unauthenticated dashboard API requests.
- Browser OIDC redirect/login/callback flow and authenticated workspace and gateway API calls.
- Manual browser confirmation of the workspaces page, platform-admin identity,
  healthy gateway indicator, and active default workspace.
- Dashboard compatibility response reporting the gateway release line as supported.
- Sandbox creation through the dashboard API, workload/supervisor readiness,
  authenticated terminal WebSocket execution with exit code 0, and completed deletion.
- Upgrade using YAML resource overrides and explicit OIDC scopes, with legacy
  installer state migrated to record the gateway identity.
- Read-only authorization verification: admin access to both test workspaces,
  ordinary-user access to its assigned workspace and HTTP 403 for the other.
  A separate live check confirmed access was denied after membership revocation.
  Browser login and sandbox/terminal smoke checks also passed after the upgrade.

These checks do not establish FIPS qualification, production certificate renewal,
isolation beyond the exercised workspace checks, or a full UI interaction test. The live
configuration and credentials are kept outside the repository.

## Prerequisites

- `uv`, Helm 3.17.3 or later, and `kubectl` on the administrator's workstation.
- An OpenShift cluster, an explicit kubeconfig context, and permission to manage
  the namespaced/cluster resources required by the charts. Permission to create
  namespaces is needed only when the selected namespace does not exist. Preflight
  also reads StorageClasses, nodes, ClusterVersion, and installer-labeled ConfigMaps
  across namespaces. System namespaces such as `default`, `kube-*`, and
  `openshift-*` are rejected.
- Agent Sandbox CRDs and a running controller installed by the cluster
  administrator. The installer checks the supported served Sandbox API and waits
  for the controller Deployment. Override `agent_sandbox_namespace` and
  `agent_sandbox_deployment` in the JSON if your installation uses different names.
- A CNI enforcing NetworkPolicy, a working default StorageClass, and cluster SCC
  configuration appropriate for the pinned gateway's sandbox runtime.
- Customer-managed HTTPS OIDC, a confidential browser client with PKCE S256,
  and access tokens whose audience and role claims match the gateway settings.
- Distinct dashboard and gateway DNS names pointing at the OpenShift router.
  The dashboard name must be covered by the router's default certificate.
- Registry access from the workstation for chart pulls and from cluster nodes
  for all images. Private image pull-secret provisioning is outside this first
  installer; use cluster-managed registry credentials if needed.

The installer does not install an IdP, Agent Sandbox, RHOAI, a modular operator,
or console integration. Administrators retain responsibility for these cluster
prerequisites. It does not change your current kubeconfig context.

## Configure and install

Copy the configuration outside the checkout so local credentials cannot be
accidentally committed:

```shell
mkdir -p "$HOME/.config/openshell-rhoai"
chmod 700 "$HOME/.config/openshell-rhoai"
cp deploy/rhoai/config.example.json "$HOME/.config/openshell-rhoai/config.json"
```

Edit the copy. Replace both version placeholders with exact published SemVer
chart versions, and set the namespace, kubeconfig context, DNS names, and OIDC
claims. The two versions need not have the same patch number. The dashboard OCI
reference currently points to its upstream publisher, not an ODH chart registry,
and that chart's default image is the upstream publisher's build. Both chart
references are configurable for mirrors.

The example sets `dashboard.images.dashboard` to the ODH build,
`quay.io/opendatahub/odh-openshell-dashboard`. Konflux builds it from each commit
of the ODH dashboard fork's `main` and tags it with that commit's full SHA. Replace
the digest placeholder with the digest of a build whose source matches the
dashboard chart version, and do not use the moving `odh-stable` tag:

| Dashboard chart | ODH fork commit | Image digest |
|---|---|---|
| `0.1.2` | `ae76c31` | `sha256:cfb3b592c5909c7c1a5d5622f98a20bf8c503554d53b3441abb189140254450b` |
| `0.1.1` | `03995be` | `sha256:77c7434a172800ce561b2910b4964728f28ada39d77f26d7039be60ed3663ece` |

Builds from fork commit `1c45566` onward add the dashboard's entitlement page,
which reads the user role the installer passes as `oidc.userRole`. Chart `0.1.2`
and later pass it to the dashboard. Chart `0.1.1` does not, so a newer build on
it refuses users whose only role is `user_role` unless that role is named `user`.

The example also sets `gateway.images` to the ODH builds of the gateway,
supervisor, and sandbox runtime (`quay.io/opendatahub/odh-openshell-gateway`,
`odh-openshell-supervisor`, and `odh-openshell-sandbox`). They are tagged
`v<OpenShell version>-rhaiv.<N>`. Use the gateway chart of the same OpenShell
version, and replace each placeholder with the digest of that tag; for example
chart `0.1.3` with `v0.1.3-rhaiv.3`. For an ODH build from an unreleased commit,
select the development chart matching the upstream commit of the downstream build.
Without `gateway.images`, the chart installs its upstream publisher's images.
`gateway.images.sandbox`, the default image for sandboxes that name none, stays
on the chart default; ODH publishes no replacement. The installer does not infer
either mapping or silently select a newer chart. Source version `0.0.0`, floating
tags, and version ranges are rejected for installation.

Save the browser client's secret to `dashboard-client-secret.txt` beside the JSON,
using a trusted editor or your secret manager. Restrict its permissions to `0600`.
Do not put the secret in the JSON, Helm values, or command arguments. File paths
in `oidc.client_secret_file` and optional `oidc.ca_file` are relative to the JSON.
The latter supplies a PEM CA bundle for a private OIDC issuer to both releases.

Register `https://<dashboard host>/oauth2/callback` with your IdP. The browser
client ID is separate from the gateway API audience. Generic OIDC uses
`allowed_groups`; Keycloak can use `provider: "keycloak-oidc"` and `allowed_roles`
such as `openshell-api:openshell-user`. These are alternatives, not assumptions
about customer claim names. Without either UI filter, any authenticated IdP user
can reach the UI, but the gateway still enforces its roles and workspace access.
Optional `oidc.scope` supplies space-separated OAuth scopes including `openid`
(for example `openid email profile offline_access`). Request only scopes your
IdP supports; include `groups` if your provider requires it for group claims.
When omitted, oauth2-proxy keeps its provider defaults.

Validate both charts without connecting to the cluster:

```shell
uv run --script --python 3.12 deploy/rhoai/install.py \
  --config "$HOME/.config/openshell-rhoai/config.json" --check
```

Install:

```shell
uv run --script --python 3.12 deploy/rhoai/install.py \
  --config "$HOME/.config/openshell-rhoai/config.json"
```

Set `namespace` in the JSON to your team/project namespace, or override it on the
command line (the override also works with `--check`):

```shell
uv run --script --python 3.12 deploy/rhoai/install.py \
  --config "$HOME/.config/openshell-rhoai/config.json" --namespace research-team
```

`--namespace` takes precedence; you may omit the JSON `namespace` when passing
this option. Both charts, Secrets, and sandbox resources target this namespace.
Gateway Service DNS and certificate SANs are derived from the selected name.
Existing namespace labels, annotations, and OpenShift SCC allocations are
preserved. Use a separate configuration with distinct public hostnames for each
gateway namespace, and register each dashboard callback with the IdP. Specifying
a different namespace creates another deployment; it does not move an existing one.

Provision a distinct API audience and browser client per gateway, even when
gateways share an issuer. The example uses `openshell-api-openshell-team` and
`openshell-dashboard-openshell-team`; change these registrations and the JSON
when selecting another namespace. `--namespace` does not rewrite OIDC identifiers
or create IdP clients. Configure per-gateway role/group mappings at your IdP;
a namespace alone is not an authentication boundary.

Preflight rejects an issuer/audience or issuer/browser-client pair already
recorded by another installer-managed namespace. It cannot discover registrations
outside this installer, tokens with multiple audiences, or old installation
state that has no identity metadata. Verify those cases with your IdP admin.

`--check` still downloads the pinned charts. It discards rendered manifests and
does not validate connectivity, SCC admission, token claims, or runtime behavior.
It reads the client secret file's existence/size, not its contents. Temporary
values files have owner-only permissions and contain no client or cookie secrets.

Run cluster preflight without installing:

```shell
uv run --script --python 3.12 deploy/rhoai/install.py \
  --config "$HOME/.config/openshell-rhoai/config.json" --preflight
```

This renders both charts, checks the default and selected workspace storage
classes, checks create/patch permissions for installation resources, verifies
Agent Sandbox readiness, and detects release/identity conflicts. It reports the
OpenShift version and node kernels and flags older kernels for runtime validation.
It does not encode a Red Hat product support matrix or prove storage health,
RBAC bind/escalate permissions, quota, SCC admission, or application compatibility.
Preflight reads supplied credential files to check for unintended rotation;
`--check` does not read their contents. `uv` installs the pinned PyYAML dependency
for parsing values files.

## Chart values

Set `gateway.values_files` and/or `dashboard.values_files` to lists of YAML or JSON
files, relative to the configuration file. Files merge in order: maps merge,
later scalars and lists replace earlier ones. Keep the same files for reruns;
the installer passes the merged result on every upgrade. Start with
[gateway-values.example.yaml](gateway-values.example.yaml) and
[dashboard-values.example.yaml](dashboard-values.example.yaml).

Supported operational overrides are:

| Chart | Values |
|---|---|
| Both | `resources`, `nodeSelector`, `tolerations`, `affinity`, `imagePullSecrets`, `openshiftRoute.annotations` |
| Gateway | `server.workspaceStorageClass`, `server.workspaceDefaultStorageSize`, `server.defaultRuntimeClassName`, `server.sandboxImagePullSecrets` |
| Dashboard | `authProxy.resources`, `authProxy.cookie.refresh`, `authProxy.upstreamTimeout`, `networkPolicy.ingressNamespace`, `networkPolicy.ingressFrom` |

For example, add `"values_files": ["gateway-values.yaml"]` to the `gateway`
section. Reference existing image-pull Secrets by name; do not put credentials
in values files. Authentication, TLS, release names, service ports, and namespace
wiring remain owned by the installer. Unsupported overrides fail before cluster
access. Extending this set requires checking the pinned charts' contracts.
The gateway chart's SQLite PVC still requires a default block-backed StorageClass;
`workspaceStorageClass` affects sandbox workspace PVCs only.

The installer creates the namespace only when missing, then creates an installer
state ConfigMap, a client/cookie Secret, and an optional OIDC CA ConfigMap.
It installs the gateway first, checks the gateway CA Secret,
and installs the dashboard with that CA and the internal gateway Service URL.
Both releases use OpenShift-assigned UID/GID settings. It waits for Helm readiness
and checks Route admission. Set `--timeout 15m` for a slower cluster.

## TLS and onboarding

The gateway uses the chart's PKI bootstrap hook and a passthrough Route. Generated
server SANs include the gateway public hostname and namespace-specific Service
names. This initial mode uses a private gateway CA: export and distribute its
`ca.crt` from `openshell-client-tls` through your trusted administrator process.
Register the gateway using the installed CLI's CA options from
`openshell gateway add --help`; do not disable certificate verification.
TLS client-certificate authentication is disabled for this OIDC-only deployment.
Supervisors retain gateway-minted sandbox JWT authentication.

The dashboard uses an edge Route and trusts the gateway CA for internal calls.
Its authentication proxy is the only exposed dashboard port. The OpenShift
router defaults to the `openshift-ingress` namespace network identity. For a
custom or host-network router, provide reviewed `networkPolicy.ingressFrom`
peers in dashboard values instead; retain ingress restricted to your router.

Configure a CLI OIDC registration separately with your IdP. After installation,
verify administrator and standard-user login. Administrators add workspace
memberships using the token's subject ID. Verify denied cross-workspace access,
sandbox creation/deletion, and terminal WebSockets before sharing the deployment.
Readiness and Route admission alone do not prove this flow works.

Use the read-only verifier after provisioning two distinct identities and two
existing workspaces. The admin must access both workspaces; the ordinary user
must belong only to the allowed workspace. Save fresh access tokens in files
with mode `0600` outside the checkout, using your IdP's supported login flow:

```shell
uv run --script --python 3.12 deploy/rhoai/verify.py \
  --context YOUR_CONTEXT --namespace research-team \
  --dashboard-url https://dashboard.apps.example.com \
  --admin-role openshell-admin \
  --admin-token-file /secure/admin-token.txt \
  --user-token-file /secure/user-token.txt \
  --allowed-workspace team-a --denied-workspace team-b
```

The verifier checks public unauthenticated rejection, gateway identity/roles,
admin access to both workspaces, ordinary-user access to one and denial in the
other. It opens a temporary loopback-only port-forward to the BFF to test gateway
authorization with bearer tokens; this requires `pods/portforward` permission.
It performs GET requests only and does not change users, memberships, or workloads.
It closes its port-forward on success or failure and never follows redirects
with credentials or prints tokens/response bodies.

Optional `--other-gateway-token-file` checks rejection of a token for another
gateway. First confirm that token works on its intended gateway: an expired or
otherwise invalid token cannot prove audience isolation. Optional
`--session-cookie-file` accepts the Cookie header value from an already logged-in
browser and checks the public session endpoint. `--ca-file` adds a private Route
CA to system trust. These checks do not automate browser login, grant/revoke,
sandbox creation/deletion, terminal execution, or network-policy enforcement.

## Reruns, upgrades, and failures

Rerun the same command after correcting a failure. The administrator selects the
namespace; it does not need an installer ownership label. The fixed release names
provide one gateway/dashboard pair per namespace. An existing gateway chart under
a different release name, or either fixed release without installer state, is
rejected and needs explicit migration. Unmanaged gateway TLS/JWT Secrets are also
rejected so the bootstrap hook cannot silently reuse another gateway's identity.
Unrelated Helm releases in the selected namespace are left alone.
Preflight inspects stored Helm workload manifests for the `openshell-gateway`
container or executable, so renaming the chart or overriding its image does not
bypass gateway detection. Failed releases and scaled-to-zero gateways count too.
Custom packaging must retain one of these markers; workloads outside Helm or
with both markers removed require administrator inspection.
Uninstalled releases retained under another name do not count as active gateways;
conflicting remaining TLS/JWT Secrets and fixed release names still require
explicit migration.

The original gateway hostname is recorded in the `openshell-installer` ConfigMap.
Issuer, API audience, and browser client ID are recorded too; changing them
requires an explicit identity migration. Legacy state is populated on a successful
preflight followed by an install/rerun without rewriting existing identity values.
Earlier installations recorded it on the namespace; reruns migrate that state
without changing namespace metadata. Changing the recorded hostname is
rejected because the certificate hook preserves existing certificates; migrate
the certificate and endpoint explicitly rather than editing installer state.

The installer preserves existing client and cookie secrets. You may omit
`client_secret_file` only when installer state exists. A first installation requires
the file even if `openshell-dashboard-oidc` already exists; the supplied client
secret must match before that Secret is reused. Preflight validates local
credential files without reading namespaced objects when the namespace is absent.
A provided secret or private OIDC CA that differs from the existing object causes
an error; rotate credentials explicitly and restart the consuming pods.
Removing `ca_file` removes the mounts
on the next upgrade, but does not delete the old ConfigMap.

Change the pinned versions to upgrade. Both Helm releases receive the generated
values with `--reset-values`, including the configured values files, so out-of-band
Helm value edits are not preserved.
There is no cross-release transaction or automatic rollback: gateway success
followed by dashboard failure leaves the upgraded gateway in place. Failed
releases, namespaces, Secrets, and PVCs are preserved for diagnosis.

Inspect the two Helm releases, namespace pods/events, and the `openshell` and
`openshell-dashboard` Routes with the same explicit kubeconfig context. For
sandbox failures, inspect Agent Sandbox, SCC admission, storage, supervisor logs,
and NetworkPolicy enforcement. Namespace deletion is never part of this script.

## Image overrides

Optional `gateway.images` accepts `gateway`, `supervisor`, `sandboxRuntime`, and
`sandbox` objects. Optional `dashboard.images` accepts `dashboard` and `authProxy`.
Each object accepts `registry`, `repository`, `tag`, and `digest`, using the chart's
image semantics. For example:

```json
"images": {
  "gateway": {
    "registry": "quay.io",
    "repository": "your-org/openshell-gateway",
    "digest": "sha256:<verified-image-digest>"
  }
}
```

Pin compatible runtime and UI images as well as chart versions. The default
workload image uses a complete registry/repository path in `sandbox.repository`
(within `gateway.images.sandbox`); its chart does not use a separate registry key.
Image overrides do not establish FIPS qualification.

## Contributor validation

The `RHOAI Installer` GitHub Actions workflow runs both suites for changes to
this directory. It needs no cluster credentials or IdP. Run them locally with:

```shell
uv run --script --python 3.12 deploy/rhoai/test_install.py
uv run --no-project --python 3.12 deploy/rhoai/test_verify.py
```

For source-chart rendering, use `--check --gateway-chart-directory <path>
--dashboard-chart-directory <path>`. These overrides are rejected for installation.
Source charts carry version `0.0.0`, so this check renders images with the versions
from your configuration. The gateway source originally selected for this work is
`348a1fc62566892ba5530ac9f35acc983e4d9324`; a source commit is not a published OCI
chart version. Resolve it to the intended release before installing.
