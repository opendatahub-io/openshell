# Install OpenShell and the OpenShell Dashboard admin UI on OpenShift

This guide walks you through installing
[OpenShell](https://github.com/NVIDIA/openshell) and the
[OpenShell Dashboard admin UI](https://github.com/ai-openshell/console) on an
existing OpenShift cluster. OpenShell provides safe, sandboxed runtimes for
autonomous AI agents; the admin UI is its browser console.

The installer deploys two Helm releases, `openshell` for the gateway and
`openshell-dashboard` for the admin UI, as one pair per namespace. The
deployment uses OIDC only: users sign in through an external identity provider,
and the gateway serves its own TLS with a private CA. After the install you
register the gateway with the OpenShell CLI. You can then sign in through OIDC
and create sandboxes and open terminals from the admin UI.

This guide is for development and evaluation, not production. It is not a
qualified RHOAI deployment: it does not cover FIPS compliance, certificate
renewal, or isolation guarantees beyond the workspace access checks described
here.

## Table of contents

- [Prerequisites](#prerequisites)
- [Choose a configuration](#choose-a-configuration)
- [Copy the configuration](#copy-the-configuration)
- [Edit the configuration](#edit-the-configuration)
  - [Required](#required)
  - [Optional](#optional)
  - [OIDC issuer certificate](#oidc-issuer-certificate)
  - [Chart and image pins](#chart-and-image-pins)
  - [Operational values overrides](#operational-values-overrides)
  - [Database backend](#database-backend)
- [Save the client secret](#save-the-client-secret)
- [Validate, preflight, and install](#validate-preflight-and-install)
- [Register the gateway and log in](#register-the-gateway-and-log-in)
- [Create and use a sandbox](#create-and-use-a-sandbox)
- [Using the OpenShell Dashboard UI](#using-the-openshell-dashboard-ui)
- [Rerun and upgrade](#rerun-and-upgrade)
- [Remove an installation](#remove-an-installation)
- [Troubleshoot common failures](#troubleshoot-common-failures)
- [Contributor checks](#contributor-checks)
- [Related documentation](#related-documentation)

## Prerequisites

- `uv`, Helm 3.17.3 or later, and `kubectl` for installation and preflight on
  the administrator's workstation. `--check` needs only Helm.
- OpenShift 4.20 or newer.
- amd64 nodes only. Mixed amd64/arm64 clusters are not supported because the
  Red Hat Build of Agent Sandbox Operator is not available on arm64.
- [Red Hat Build of Agent Sandbox
  Operator](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/index)
  deployed in the cluster.
- OpenShift's default OVN-Kubernetes network plugin (NetworkPolicy support)
  and a default StorageClass that provisions block volumes for the gateway's
  SQLite database.
- An OIDC provider with a confidential browser client that uses PKCE S256. For
  development, set one up with the
  [Keycloak development guide](keycloak-dev-guide.md).
- Registry access: `ghcr.io` from the workstation or server where the
  installer is being run for both Helm charts, and from the cluster nodes the
  registries your images come from: `quay.io` for ODH builds and
  `registry.redhat.io` for RHOAI builds (requires a pull secret).
  `registry.access.redhat.com` is only needed when you use a Red Hat base image.

The installer does not install an identity provider, Agent Sandbox, RHOAI, or
console integration. It targets the current kubeconfig context unless you pass
`--context`, and never changes it. Configurations do not select a context.
`--check` reads neither the context nor the cluster.

## Choose a configuration

Start with `config-examples/config.example-rhoai-3.6-keycloak.json`. It pins the
RHOAI 3.6 builds by digest and pairs them with the Keycloak realm that
[keycloak-dev-guide.md](keycloak-dev-guide.md) creates.

For the latest OpenShell builds, use
`config-examples/config.example-odh-keycloak.json`. It pins gateway chart
`0.1.7` and the `v0.1.7-rhaiv.0` images. It uses only `quay.io` images, so it
can test Open Data Hub community builds without `registry.redhat.io` access or
a pull secret.

[config-examples/README.md](config-examples/README.md) describes all five
examples, including the generic and non-Keycloak variants.

## Copy the configuration

Copy the example outside the checkout so local credentials cannot be committed.
The commands below keep the configuration and its files in `CONFIG_DIR`; set it
to the directory that contains `config.json` if you keep it elsewhere:

```shell
export CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openshell-rhoai"
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
cp deploy/rhoai/config-examples/config.example-rhoai-3.6-keycloak.json \
  "$CONFIG_DIR/config.json"
chmod 600 "$CONFIG_DIR/config.json"
```

Users who want operational overrides also copy
`config-examples/gateway-values.example.yaml` and/or
`config-examples/dashboard-values.example.yaml` beside the configuration. The
[Operational values overrides](#operational-values-overrides) section explains
how to wire them.

## Edit the configuration

Review the required fields first. They describe the deployment target and the
identity provider registration. The examples already pin published charts and
images; check them against [Chart and image pins](#chart-and-image-pins).

### Required

- `namespace` is the application namespace, for example `openshell-team`. The
  installer rejects `default`, `kube-*`, and `openshift-*`. It deploys one
  gateway and dashboard pair per namespace, and each pair needs distinct hosts
  and OIDC identifiers: the OpenShift router does not admit the same host from
  two namespaces.
- `gateway.chart`, `gateway.version`, `dashboard.chart`, and `dashboard.version`
  are required. The examples pin published versions; replace the
  `REPLACE_WITH_*` placeholders when you copy `config.example.json`.
- `oidc.issuer` is the provider's issuer URL.
- `oidc.client_id` is the dashboard browser client, conventionally
  `openshell-dashboard-<namespace>`. The Keycloak examples use
  `openshell-dashboard-openshell-team`.
- `oidc.audience` is the gateway API audience, conventionally
  `openshell-api-<namespace>`, for example `openshell-api-openshell-team`. It
  must differ from the client ID.
- `oidc.roles_claim` names the claim path the provider emits. Use
  `realm_access.roles` for the Keycloak walkthrough; the generic examples use
  `roles`.
- `oidc.admin_role` and `oidc.user_role` are the role names the gateway and
  dashboard recognize.
- `oidc.client_secret_file` names the browser client secret file. It is required
  for the first install, and paths in this field and `oidc.ca_file` resolve
  relative to the configuration file.

### Optional

- `gateway.host` and `dashboard.host` are optional. When omitted, the installer
  derives `gateway-<namespace>.<apps-domain>` and
  `dashboard-<namespace>.<apps-domain>` from the cluster ingress domain
  (`ingresses.config.openshift.io/cluster` `.spec.domain`), using the effective
  namespace including `--namespace`. Set them explicitly to use a different
  router domain; explicit hosts do not follow `--namespace`. Both hosts must be
  distinct and sit under the router's `*.apps.<domain>` wildcard so DNS
  resolves. The dashboard's edge Route uses the router certificate; the gateway
  serves its own certificate through a passthrough Route.
- `context` is not a configuration field. Pass `--context` to select a kube
  context; otherwise the installer uses the current kubeconfig context.
- `oidc.allowed_roles` is a dashboard login filter. The installer accepts it only
  when `oidc.provider` is `keycloak-oidc`; for generic `oidc`, use
  `oidc.allowed_groups`. The Keycloak examples list both roles that
  [keycloak-dev-guide.md](keycloak-dev-guide.md) creates, as an example choice,
  not a requirement; with `keycloak-oidc`, any role list the provider emits works.
- `oidc.scope` is the space-separated OAuth scope request, for example
  `openid email profile`. Omit it to keep the provider defaults.
- `oidc.cli_client_id` is the public client the `openshell` CLI registers as.
  It defaults to `openshell-cli-<namespace>`; keep that default so each
  gateway's CLI client carries only its own audience.

Register `https://<dashboard-host>/oauth2/callback` with the identity provider.
With the default configuration, `<dashboard-host>` is
`dashboard-<namespace>.<apps-domain>`.

### OIDC issuer certificate

Set `ca_file` in the config file only when the OIDC issuer's certificate is not publicly trusted,
for example a self-signed certificate or a private CA. The Keycloak examples
set `"ca_file": "ingress-ca.crt"` because the development Keycloak serves
through an OpenShift Route that uses the cluster's default ingress certificate,
which is self-signed.

Create that file before `--check`:

```shell
oc -n openshift-config-managed get configmap default-ingress-cert \
  -o jsonpath='{.data.ca-bundle\.crt}' \
  > "$CONFIG_DIR/ingress-ca.crt"
```

When `ca_file` is set, the installer creates the `openshell-oidc-ca` ConfigMap
and mounts it in both releases so the gateway and dashboard trust the issuer.
Leave the field unset for publicly trusted issuers, such as an external
identity provider or a cluster with custom router certificates; the installer
then creates no ConfigMap and both workloads use the system trust roots.

### Chart and image pins

- `version` in each section is the OpenShell Helm chart version, not the image tag.
- RHOAI image digests come from the rhods-operator.3.6.0 CSV. Refresh them with the command
  in [config-examples/README.md](config-examples/README.md), or use the
  `rhoai-3.6` tag instead.
- The ODH examples use `v0.1.7-rhaiv.0` images.
- When both are present, `digest` takes precedence over `tag`.
- `gateway.images.sandbox` uses a full repository path and has no separate
  registry key. The image must provide a shell at `/bin/bash`, `/usr/bin/bash`,
  or `/bin/sh`.
- Supported architectures: the installer runs on amd64-only clusters. Mixed
  amd64/arm64 clusters are not supported because the Red Hat Build of Agent
  Sandbox Operator is not available on arm64. The RHOAI 3.6 images and the ODH
  gateway, supervisor, and sandbox images are already multi-arch, but the ODH
  dashboard image is amd64-only and pairs with dashboard chart `0.1.2`.
- Use the `vX.Y.Z-rhaiv.N` tagged images for ODH, not the moving `odh-stable`
  tag.

### Operational values overrides

`gateway.values_files` and `dashboard.values_files` list YAML or JSON files
whose paths resolve relative to the configuration. The installer merges the
files in order and re-applies the result on every install and rerun. See
[Chart values](config-examples/README.md#chart-values) for the allowed
override set.

`config-examples/gateway-values.example.yaml` and
`config-examples/dashboard-values.example.yaml` are optional, ready-to-edit
values overrides for the operational knobs the installer allows: resource
requests and limits, `imagePullSecrets`, gateway
`server.workspaceStorageClass`, dashboard `authProxy` settings, and router
NetworkPolicy peers. Copy a file beside the private configuration, edit the
sizes and fields for the workload, and add its filename to the matching chart's
`values_files` list, for example:

```json
"values_files": ["gateway-values.yaml"]
```

Skipping them installs the chart defaults. Keep the same files on reruns so the
upgrade applies the intended values.

### Database backend

This installer always deploys the gateway with its default SQLite database.
Preflight requires a default block-backed StorageClass for the gateway's PVC,
and the values allowlist rejects database settings. This is a limitation of the
installer script, not of OpenShell: the gateway chart accepts
`server.externalDbSecret` with a Secret that holds a PostgreSQL connection URI.
Using PostgreSQL requires extending the installer or installing the chart
directly.

## Save the client secret

Save the secret of the dashboard browser client from Keycloak or your OIDC
provider beside the configuration:

```shell
umask 077
mkdir -p "$CONFIG_DIR"
IFS= read -rs -p 'Dashboard client secret: ' SECRET
printf '%s' "$SECRET" > "$CONFIG_DIR/dashboard-client-secret.txt"
unset SECRET
chmod 600 "$CONFIG_DIR/dashboard-client-secret.txt"
```

The `read -rs` prompt keeps the secret off the screen and out of the shell
history. When the
[Keycloak client helper](keycloak-dev-guide-create-openshell-clients.sh) created
the client, it already wrote this file; skip this step in that case. Do not put
the secret in the JSON, Helm values, or command arguments.

## Validate, preflight, and install

The script's shebang runs it through `uv`, which installs its pinned PyYAML
dependency, so `uv` must be on your `PATH`.

Validate both charts without touching the cluster:

```shell
./deploy/rhoai/install.py \
  --config "$CONFIG_DIR/config.json" --check
```

Expect `Both charts rendered successfully. This does not verify cluster or API
compatibility.` The check downloads the pinned charts but does not access the
cluster.

When a configuration omits the hosts, `--check` renders them as
`gateway-<namespace>.apps.example.com` and
`dashboard-<namespace>.apps.example.com`; the install derives the real hosts
from the cluster. Pass `--apps-domain <domain>` to render the real derived hosts
offline.

Run cluster preflight without installing:

```shell
./deploy/rhoai/install.py \
  --config "$CONFIG_DIR/config.json" --preflight
```

Expect `Cluster preflight passed; no installation resources were changed.`
Preflight prints the target context and namespace. When a host is omitted, it
also resolves the ingress apps domain and uses the derived hosts for the
installer's identity checks.

Install:

```shell
./deploy/rhoai/install.py \
  --config "$CONFIG_DIR/config.json"
```

The installer prints the dashboard and gateway URLs. `--namespace` overrides the
namespace; when hosts are omitted, the derived hosts follow it. Explicit hosts
and OIDC identifiers do not change, so keep the provider registrations in sync.
`--context` overrides the kube context. Set `--timeout 15m` for a slower
cluster. On failure, the installer leaves the created resources for diagnosis;
correct the cause and rerun the same command.

When the install finishes, the installer also prints the next steps with your
configuration values: install the matching OpenShell CLI, register the gateway
with its CA, check the connection with `openshell status`, and create a sandbox
with `openshell sandbox create`. The printed `kubectl` command includes the kube
context the install targeted, so it reads the CA Secret from the same cluster.
The following sections describe the same steps in more detail, including the
trust setup for custom identity providers.

## Register the gateway and log in

The installer prints these commands with the values from your configuration; use
its output when it differs from the examples below.

Install the OpenShell CLI. The examples in this guide use `v0.1.7`; install the
version that matches the gateway release you deployed:

```shell
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh \
  | OPENSHELL_VERSION=v0.1.7 sh
```

The upstream installer also deploys and starts a local gateway on the
workstation that runs it: a user service on Linux and a Homebrew service on
macOS. This is a limitation of the upstream installer. The local gateway is
separate from the cluster gateway deployed above and is not used by this
guide's remote-cluster workflow. If it conflicts with an existing local
installation, remove it with `openshell gateway destroy`.

The gateway Route is TLS passthrough serving a private CA, and OIDC discovery
uses the ingress CA. Trust both paths before adding the gateway.

Set `CTX` to the context you installed with — the value passed to `--context`,
or the current kubeconfig context when `--context` was not passed — so the
certificate commands below read from the same cluster:

```shell
CTX=YOUR_INSTALL_CONTEXT
```

Copy the gateway server CA into the CLI's per-gateway TLS directory. The
directory name must match the `--name` value you use below:

```shell
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/openshell-team/mtls"
oc --context "$CTX" -n openshell-team get secret openshell-client-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 -d \
  > "${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/openshell-team/mtls/ca.crt"
```

The CLI stores gateway metadata under `${XDG_CONFIG_HOME:-$HOME/.config}/openshell`.

OIDC bearer authentication needs only `ca.crt` in this directory.

Build an `SSL_CERT_FILE` bundle from the system roots plus the ingress CA.
Skip this and the ConfigMap command below when your OIDC issuer's certificate
is publicly trusted (`oidc.ca_file` unset): the installer creates no
`openshell-oidc-ca` ConfigMap, no ingress CA file exists, and the CLI uses the
system trust roots unchanged. Setting `SSL_CERT_FILE` replaces the default
bundle, so never point it at the ingress CA alone:

```shell
cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
  "$CONFIG_DIR/ingress-ca.crt" \
  > "$CONFIG_DIR/ca-bundle.pem"
export SSL_CERT_FILE="$CONFIG_DIR/ca-bundle.pem"
```

The installer prints the system bundle path it detects for the host it runs
on. If you run these commands on another host, substitute the matching path:
`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` on Fedora and RHEL,
`/etc/ssl/certs/ca-certificates.crt` on Debian and Ubuntu, and
`/etc/ssl/cert.pem` on macOS. You may also source the ingress CA from the
installer-created ConfigMap:

```shell
oc --context "$CTX" -n openshell-team get configmap openshell-oidc-ca \
  -o jsonpath='{.data.ca\.crt}' > "$CONFIG_DIR/ingress-ca.crt"
```

Register the gateway:

```shell
openshell gateway add \
  --name openshell-team \
  --oidc-issuer "https://keycloak.apps.example.com/realms/openshell" \
  --oidc-client-id openshell-cli-openshell-team \
  --oidc-audience openshell-api-openshell-team \
  "https://gateway-openshell-team.apps.example.com:443"
```

Replace the issuer with your configuration value. The gateway URL is the derived
default `gateway-<namespace>.<apps-domain>`; use the URL the installer printed.
The command opens a browser for the Authorization Code + PKCE login.

Sign in as a user that holds the gateway's admin role or user role. The admin
role is configured in `oidc.admin_role` (`openshell-admin` in the Keycloak
examples), and the user role in `oidc.user_role` (`openshell-user`). A user who
holds neither role can complete the login, but the gateway rejects their API
calls. A user with the admin role creates workspaces and must add users as
members before those users can work there; a user with the user role works only
in workspaces where they are a member.

The CLI targets the `default` workspace unless you select another one. If an
administrator assigned you to a different workspace, pass `--workspace <name>`
to each command or export `OPENSHELL_WORKSPACE=<name>`; your account may not be
authorized for the `default` workspace. See
[Workspaces](https://docs.nvidia.com/openshell/latest/how-it-works/workspaces)
for workspace creation and membership.

Verify the registration and login:

```shell
openshell status
```

Expect `Status: Connected` and `Authentication: Authenticated (OIDC)`.

`--gateway-insecure` skips gateway certificate verification for local testing
only; do not use it beyond development. For the identity-provider side, see
[keycloak-dev-guide.md](keycloak-dev-guide.md).

## Create and use a sandbox

List the sandbox subcommands:

```shell
openshell sandbox --help
```

Create a sandbox:

```shell
openshell sandbox create
```

The gateway assigns the sandbox an auto-generated name, for example
`juicy-lacewing`. Exit the initial shell with Control+D to keep the sandbox
running; pass `--no-keep` to delete it when the shell exits instead.

List the sandboxes in the workspace:

```shell
openshell sandbox list
```

Stop, start, and reconnect to a sandbox by name:

```shell
openshell sandbox stop juicy-lacewing
openshell sandbox start juicy-lacewing
openshell sandbox connect juicy-lacewing
```

For more comprehensive sandbox and agent examples, see
[Run Your First Agent](https://docs.nvidia.com/openshell/latest/about/run-your-first-agent)
and [How it works](https://docs.nvidia.com/openshell/how-it-works).

## Using the OpenShell Dashboard UI

The installer deploys the dashboard beside the gateway and prints its URL. With
omitted hosts, the URL is `https://dashboard-<namespace>.<apps-domain>`; when
hosts are set explicitly, use the value the installer printed. Open the URL and
sign in through the configured OIDC provider.

The dashboard shows different features depending on the signed-in user's role.
With `oidc.provider: "keycloak-oidc"`, the account must hold a role listed in
`oidc.allowed_roles`; the Keycloak examples list `openshell-admin` and
`openshell-user`. With generic `oidc`, list the provider's group in
`oidc.allowed_groups` instead. When neither filter is set, any authenticated
identity-provider user can reach the UI, but the gateway still enforces its
roles and workspace access. A user with the admin role
(`oidc.admin_role`) can create workspaces and add users to them. A user with the
user role (`oidc.user_role`) sees the workspaces they were added to and manages
them, including creating sandboxes.

Use the dashboard to:

- Create and delete workspaces and manage their members (admin role).
- Create sandboxes with a policy or from a workspace template, then stop, start,
  and delete them.
- Open a sandbox to view its logs, use an interactive terminal, upload and
  download files, inspect exposed services and attached providers, and review
  its settings.
- Manage network policy with revision history, a network-rule editor, and
  proposed policy changes per sandbox.
- Register provider credentials and manage provider profiles.
- View gateway status, version, compute drivers, settings, and resources across
  all workspaces.

For more information about the dashboard, see
[ai-openshell/console](https://github.com/ai-openshell/console).

## Rerun and upgrade

Rerun the same command after correcting a failure. Both releases receive the
generated values with `--reset-values`, including the configured values files,
so out-of-band Helm value edits are not preserved.

Changing the gateway host, issuer, audience, or client ID is rejected by the
`openshell-installer` state and needs an explicit identity migration. When hosts
are omitted, changing the namespace or the cluster apps domain changes the
derived gateway host and triggers the same check.

A changed client secret or OIDC CA requires explicit rotation. Set `CTX` to the
context used for the installation (the `--context` value, or the current
kubeconfig context when `--context` was not passed), then update the Secret
while preserving `cookie-secret` and restart the dashboard:

```shell
CTX=YOUR_INSTALL_CONTEXT
COOKIE_FILE=$(mktemp)
oc --context "$CTX" -n openshell-team get secret openshell-dashboard-oidc \
  -o jsonpath='{.data.cookie-secret}' | base64 -d > "$COOKIE_FILE"
oc --context "$CTX" -n openshell-team create secret generic openshell-dashboard-oidc \
  --from-file=client-secret="$CONFIG_DIR/dashboard-client-secret.txt" \
  --from-file=cookie-secret="$COOKIE_FILE" \
  --dry-run=client -o yaml | oc --context "$CTX" apply -f -
rm -f "$COOKIE_FILE"
oc --context "$CTX" -n openshell-team rollout restart deployment openshell-dashboard
```

When the OIDC issuer's CA changes and `oidc.ca_file` is set, also rotate the
`openshell-oidc-ca` ConfigMap that both releases mount. The Secret commands
above do not update it, so the gateway and dashboard keep trusting the old CA
and fail issuer TLS verification; the installer also rejects a rerun until the
ConfigMap matches the new `ca_file`. Update the ConfigMap and restart both
workloads:

```shell
oc --context "$CTX" -n openshell-team create configmap openshell-oidc-ca \
  --from-file=ca.crt="$CONFIG_DIR/ingress-ca.crt" \
  --dry-run=client -o yaml | oc --context "$CTX" apply -f -
oc --context "$CTX" -n openshell-team rollout restart \
  "$(oc --context "$CTX" -n openshell-team get statefulset,deployment \
    -l app.kubernetes.io/name=openshell,app.kubernetes.io/instance=openshell -o name)"
oc --context "$CTX" -n openshell-team rollout restart deployment openshell-dashboard
```

The gateway runs as StatefulSet `openshell` with the default SQLite backend and
as Deployment `openshell` when `server.externalDbSecret` is configured. The
selector restarts whichever object the release uses without naming its kind.

There is no cross-release transaction or automatic rollback: a gateway success
followed by a dashboard failure leaves the upgraded gateway in place.

## Remove an installation

The installer has no uninstall subcommand. Set `CTX` to the context used for the
installation (the `--context` value, or the current kubeconfig context when
`--context` was not passed), then remove the dashboard first, then the gateway:

```shell
CTX=YOUR_INSTALL_CONTEXT
helm uninstall openshell-dashboard -n openshell-team --kube-context "$CTX"
helm uninstall openshell -n openshell-team --kube-context "$CTX"
```

The gateway chart's certificate hook creates three Secrets outside the release
manifest, so `helm uninstall` does not remove them. Delete them and the
installer-owned authentication objects:

```shell
oc --context "$CTX" -n openshell-team delete secret \
  openshell-server-tls openshell-client-tls openshell-jwt-keys
oc --context "$CTX" -n openshell-team delete secret openshell-dashboard-oidc
oc --context "$CTX" -n openshell-team delete configmap openshell-oidc-ca
```

Optionally delete the installer state ConfigMap and the namespace:

```shell
oc --context "$CTX" -n openshell-team delete configmap openshell-installer
oc --context "$CTX" delete namespace openshell-team
```

Remaining Secrets block a later reinstall and can be reused by a new gateway if
you keep the same names. PersistentVolumeClaims are not deleted by any of these
commands; inspect and remove them deliberately. The installer never deletes the
namespace for you.

## Troubleshoot common failures

| Symptom | Cause and fix |
|---|---|
| `oidc.client_secret_file is required for the first install` | Create the client secret file before `--check`, or reuse installer state from an earlier successful install. |
| No default StorageClass | Mark a StorageClass that provisions block volumes as default; the gateway's SQLite database needs it. |
| Preflight fails with `This installer supports amd64 clusters only` | The cluster has non-amd64 nodes, including a mixed amd64/arm64 cluster. Mixed clusters are not supported because the Red Hat Build of Agent Sandbox Operator is not available on arm64; run the installer against an amd64-only cluster. |
| Agent Sandbox readiness fails | Install or start the Agent Sandbox controller, or override `agent_sandbox_namespace` and `agent_sandbox_deployment`. |
| `x509` error during `openshell gateway add` | Distinguish the two trust paths: copy the gateway CA into the CLI mtls directory, and build the `SSL_CERT_FILE` bundle for OIDC discovery. |
| `dns error` from `openshell status` after `gateway add` succeeds | The gateway host is outside the router's `*.apps.<domain>` wildcard, so it has no DNS record. Registration only contacts the OIDC issuer; `status` is the first gateway connection. Correct `gateway.host`, or remove it to derive `gateway-<namespace>.<apps-domain>` from the ingress domain. Reinstall when the installer already recorded the old host. |
| `Could not resolve the OpenShift apps domain` | Grant read access to `ingresses.config.openshift.io/cluster`, or set `gateway.host` and `dashboard.host` explicitly. |
| HTTP 403 after login | The user holds no role in `allowed_roles`, or no group in `allowed_groups` for generic OIDC. Add a listed role or group to the user, then rerun the install command. |
| Gateway host or issuer change is rejected | The installer state records the original identity. With omitted hosts, a namespace or ingress-domain change also changes the gateway host. Migrate the certificate and endpoint explicitly instead of editing state. |

For Keycloak-specific failures, see
[Troubleshooting](keycloak-dev-guide.md#troubleshooting) in the Keycloak
development guide.

## Contributor checks

The `RHOAI Installer` workflow runs both suites for changes under
`deploy/rhoai/`. Run the same checks locally:

```shell
uv run --script --python 3.12 deploy/rhoai/test_install.py
uv run --no-project --python 3.12 deploy/rhoai/test_verify.py
uvx ruff==0.14.14 check deploy/rhoai
uvx ruff==0.14.14 format --check deploy/rhoai
mise run markdown:lint
```

The installer and verifier tests need no cluster credentials or identity
provider. For source-chart rendering, use `--check` with
`--gateway-chart-directory` and `--dashboard-chart-directory`; the installer
rejects those overrides for installation.

## Related documentation

- [config-examples/README.md](config-examples/README.md): example
  configurations and values files.
- [keycloak-dev-guide.md](keycloak-dev-guide.md): development Keycloak
  deployment for OpenShell.
- [verify.py](verify.py): read-only authorization verification with
  administrator and ordinary-user tokens.
