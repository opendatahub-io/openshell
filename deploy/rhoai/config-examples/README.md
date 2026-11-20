# RHOAI installer example configurations

This directory holds the example configurations and optional values files for
the `--config` installer described in [../README.md](../README.md).

## Using an example

Copy an example outside the checkout, then replace the chart, version, image,
and OIDC placeholders before installing:

```shell
cp deploy/rhoai/config-examples/config.example-odh-keycloak.json \
  "${XDG_CONFIG_HOME:-$HOME/.config}/openshell-rhoai/config.json"
```

Paths in `oidc.client_secret_file` and `oidc.ca_file` resolve relative to the
configuration file. Create the client secret file before `--check`; the
installer validates that the file exists and is not empty. The Keycloak
examples also set `"ca_file": "ingress-ca.crt"`, so create that file with the
command in [../README.md](../README.md#oidc-issuer-certificate) before running
`--check`.

The examples omit the hosts. The installer targets the current kubeconfig
context (`--context` selects another one) and derives
`gateway-<namespace>.<apps-domain>` and `dashboard-<namespace>.<apps-domain>`
from the cluster ingress domain.

## Example values files

`gateway-values.example.yaml` and `dashboard-values.example.yaml` are optional
Helm values overrides, not configurations. Use them to set the operational
knobs the installer permits: resource requests and limits,
`nodeSelector`/`tolerations`/`affinity`, `imagePullSecrets`, gateway
`server.workspaceStorageClass` and `sandboxImagePullSecrets`, dashboard
`authProxy` resources and timeouts, and router `networkPolicy.ingressFrom`
peers.

Copy a file beside the private configuration, edit it, and list its filename in
the matching chart's `values_files`. Paths resolve relative to the
configuration:

```json
"values_files": ["gateway-values.yaml"]
```

Files merge in order and are re-applied with `--reset-values` on every rerun,
so keep the same files. Omitting them installs the chart defaults.

## Example table

| File | Images | Gateway chart | Dashboard chart | OIDC | Use when |
|---|---|---|---|---|---|
| `config.example.json` | ODH repositories, digest placeholders | placeholder | placeholder | generic | custom registries or versions |
| `config.example-odh.json` | ODH `v0.1.7-rhaiv.0` | `0.1.7` | `0.1.2` | generic | latest OpenShell with your own IdP |
| `config.example-odh-keycloak.json` | ODH `v0.1.7-rhaiv.0` | `0.1.7` | `0.1.2` | Keycloak | latest OpenShell with Keycloak |
| `config.example-rhoai-3.6.json` | RHOAI 3.6 digests | `0.1.3` | `0.1.2` | generic | match the RHOAI 3.6 operator CSV |
| `config.example-rhoai-3.6-keycloak.json` | RHOAI 3.6 digests | `0.1.3` | `0.1.2` | Keycloak | default README walkthrough |

All examples omit the hosts and rely on the defaults described below.

## OIDC identifiers

The Keycloak examples use namespace-qualified
`openshell-dashboard-<namespace>`, `openshell-api-<namespace>`, and
`openshell-cli-<namespace>` client IDs, with `openshell-team` as the default. The non-Keycloak examples follow the same
convention. When you change the namespace, update the client IDs and audience in
`config.json`, the provider registrations, and
`openshell gateway add --oidc-audience`.

Derived hosts follow the effective namespace automatically. Explicit
`gateway.host` and `dashboard.host` values do not follow it.

## Optional fields

These fields are optional; the installer derives or defaults them:

| Field | Default |
|---|---|
| `gateway.host`, `dashboard.host` | `gateway-<namespace>.<apps-domain>` and `dashboard-<namespace>.<apps-domain>` |
| `oidc.cli_client_id` | `openshell-cli-<namespace>` |
| `gateway.values_files`, `dashboard.values_files` | `[]` |
| `gateway.images`, `dashboard.images` | Chart defaults |
| `agent_sandbox_namespace` | `agent-sandbox-system` |
| `agent_sandbox_deployment` | `agent-sandbox-controller` |
| `oidc.provider` | `oidc` |
| `oidc.allowed_groups`, `oidc.allowed_roles` | `[]` |
| `oidc.client_secret_file`, `oidc.ca_file` | none |
| `oidc.scope` | Provider defaults |

`oidc.allowed_roles` is accepted only with `oidc.provider: "keycloak-oidc"`.
Generic OIDC configurations restrict the dashboard login with
`oidc.allowed_groups` instead.

Set a host explicitly when the router serves a wildcard that differs from
`ingresses.config.openshift.io/cluster` `.spec.domain`. `--check` renders
omitted hosts as `<component>-<namespace>.apps.example.com` unless you pass
`--apps-domain`.

## ODH images

Konflux publishes ODH builds from `main` (`odh-stable`) and as
`vX.Y.Z-rhaiv.N` tags. Use the `vX.Y.Z-rhaiv.N` tags, not `odh-stable`. The
0.1.7 examples use `v0.1.7-rhaiv.0`, which is multi-architecture. All ODH
images come from `quay.io`, so no `registry.redhat.io` access or pull secret is
needed. Pin a tag or digest, and match the gateway chart version to the
OpenShell version.

## RHOAI images

RHOAI image digests come from the installed operator CSV. After installing
OpenShift AI, print the current images with:

```shell
oc get csv rhods-operator.3.6.0 -n redhat-ods-operator -o yaml | grep -A1 OPENSHELL
```

Use the printed `registry.redhat.io/rhoai/...@sha256:...` values in the
examples. Alternatively, replace each `digest` with the release tag:

```json
"tag": "rhoai-3.6"
```

Digests keep installs reproducible; a tag is resolved when the pod starts and
can change when Red Hat republishes it.

## Dashboard pairing

Dashboard chart `0.1.2` is the first chart that passes `USER_ROLE` to the
dashboard. ODH dashboard builds are amd64-only and tagged with their commit;
do not use the moving `odh-stable` tag. The ODH examples pin
`sha256:cfb3b592c5909c7c1a5d5622f98a20bf8c503554d53b3441abb189140254450b`.

## Tags and digests

- `digest` takes precedence when an image sets both `digest` and `tag`.
- An empty `digest` is passed through unchanged.
- Chart versions accept exact SemVer only; source version `0.0.0`, floating
tags, and ranges are rejected.
- `gateway.images.sandbox` has no registry key and uses a full repository path.
The image must provide a shell at `/bin/bash`, `/usr/bin/bash`, or `/bin/sh`.

## Chart values

Maps merge; later scalars and lists replace earlier ones. Supported
operational overrides are:

| Chart | Values |
|---|---|
| Both | `resources`, `nodeSelector`, `tolerations`, `affinity`, `imagePullSecrets`, `openshiftRoute.annotations` |
| Gateway | `server.workspaceStorageClass`, `server.workspaceDefaultStorageSize`, `server.defaultRuntimeClassName`, `server.sandboxImagePullSecrets` |
| Dashboard | `authProxy.resources`, `authProxy.cookie.refresh`, `authProxy.upstreamTimeout`, `networkPolicy.ingressNamespace`, `networkPolicy.ingressFrom` |

Reference existing image-pull Secrets by name; do not put credentials in
values files. Authentication, TLS, release names, service ports, and namespace
wiring remain owned by the installer. Unsupported overrides fail before cluster
access. Extending this set requires checking the pinned charts' contracts.
The gateway chart's SQLite PVC still requires a default block-backed
StorageClass; `workspaceStorageClass` affects sandbox workspace PVCs only.

## Local files

`config.json`, `config.json-backup*`, client secrets, and override YAML files
are local working files. Do not commit them; only the `*.example.*` files in
this directory belong in the repository.
