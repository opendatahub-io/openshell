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

## Prerequisites

- `uv`, Helm 3.17.3 or later, and `kubectl` on the administrator's workstation.
- OpenShift 4.20 or newer.
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
console integration. It does not change your current kubeconfig context.

## Choose a configuration

Start with `config-examples/config.example-rhoai-3.6-keycloak.json`. It pins the
RHOAI 3.6 builds by digest and pairs them with the Keycloak realm that
[keycloak-dev-guide.md](keycloak-dev-guide.md) creates.

For the latest OpenShell builds, use
`config-examples/config.example-odh-keycloak.json`. It pins gateway chart
`0.1.6` and the `v0.1.6-rhaiv.3` images. It uses only `quay.io` images, so it
can test Open Data Hub community builds without `registry.redhat.io` access or
a pull secret.

[config-examples/README.md](config-examples/README.md) describes all five
examples, including the generic and non-Keycloak variants.

## Copy the configuration

Copy the example outside the checkout so local credentials cannot be committed:

```shell
mkdir -p "$HOME/.config/openshell-rhoai"
chmod 700 "$HOME/.config/openshell-rhoai"
cp deploy/rhoai/config-examples/config.example-rhoai-3.6-keycloak.json \
  "$HOME/.config/openshell-rhoai/config.json"
chmod 600 "$HOME/.config/openshell-rhoai/config.json"
```

Users who want operational overrides also copy
`config-examples/gateway-values.example.yaml` and/or
`config-examples/dashboard-values.example.yaml` beside the configuration. The
[Operational values overrides](#operational-values-overrides) section explains
how to wire them.

## Edit the configuration

- `context` is the kubeconfig context to install into. Run
  `kubectl config current-context` to copy the active one.
- `namespace` is the application namespace, for example `openshell-team`. The
  installer rejects `default`, `kube-*`, and `openshift-*`. It deploys one
  gateway and dashboard pair per namespace, and each pair needs distinct hosts
  and OIDC identifiers: the OpenShift router does not admit the same host from
  two namespaces.
- `gateway.host` and `dashboard.host` are distinct public hostnames, qualified
  with the namespace, as in the examples
  (`gateway-openshell-team.apps.example.com`). Both must sit under the router's
  `*.apps.<domain>` wildcard so DNS resolves. The dashboard's edge Route uses
  the router certificate; the gateway serves its own certificate through a
  passthrough Route.
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
- `oidc.allowed_roles` is a dashboard login filter. The Keycloak examples list
  both roles that [keycloak-dev-guide.md](keycloak-dev-guide.md) creates, as an
  example choice, not a requirement; any role list the provider emits works.
- `oidc.scope` is the space-separated OAuth scope request, for example
  `openid email profile`. Omit it to keep the provider defaults.
- `oidc.client_secret_file` names the browser client secret file. Paths in this
  field and `oidc.ca_file` resolve relative to the configuration file.

Register `https://<dashboard-host>/oauth2/callback` with the identity provider.

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
  > "$HOME/.config/openshell-rhoai/ingress-ca.crt"
```

When `ca_file` is set, the installer creates the `openshell-oidc-ca` ConfigMap
and mounts it in both releases so the gateway and dashboard trust the issuer.
Leave the field unset for publicly trusted issuers, such as an external
identity provider or a cluster with custom router certificates; the installer
then creates no ConfigMap and both workloads use the system trust roots.

### Chart and image pins

- `version` in each section is the Helm chart version, not the image tag.
- RHOAI image digests come from the operator CSV. Refresh them with the command
  in [config-examples/README.md](config-examples/README.md), or use the
  `rhoai-3.6` tag instead.
- The ODH examples use `v0.1.6-rhaiv.3` images.
- When both are present, `digest` takes precedence over `tag`.
- `gateway.images.sandbox` uses a full repository path and has no separate
  registry key. The image must provide a shell at `/bin/bash`, `/usr/bin/bash`,
  or `/bin/sh`.
- ODH dashboard images are amd64-only and pair with dashboard chart `0.1.2`.
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
printf '%s' '<dashboard-client-secret>' \
  > "$HOME/.config/openshell-rhoai/dashboard-client-secret.txt"
chmod 600 "$HOME/.config/openshell-rhoai/dashboard-client-secret.txt"
```

Do not put the secret in the JSON, Helm values, or command arguments.

## Validate, preflight, and install

The script's shebang runs it through `uv`, which installs its pinned PyYAML
dependency, so `uv` must be on your `PATH`.

Validate both charts without touching the cluster:

```shell
./deploy/rhoai/install.py \
  --config "$HOME/.config/openshell-rhoai/config.json" --check
```

Expect `Both charts rendered successfully. This does not verify cluster or API
compatibility.` The check downloads the pinned charts but does not access the
cluster.

Run cluster preflight without installing:

```shell
./deploy/rhoai/install.py \
  --config "$HOME/.config/openshell-rhoai/config.json" --preflight
```

Expect `Cluster preflight passed; no installation resources were changed.`

Install:

```shell
./deploy/rhoai/install.py \
  --config "$HOME/.config/openshell-rhoai/config.json"
```

The installer prints the dashboard and gateway URLs. `--namespace` overrides
only the namespace, not the hosts or OIDC identifiers. Set `--timeout 15m` for
a slower cluster. On failure, the installer leaves the created resources for
diagnosis; correct the cause and rerun the same command.

## Register the gateway and log in

Install the OpenShell CLI. The examples in this guide use `v0.1.6`; install the
version that matches the gateway release you deployed:

```shell
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh \
  | OPENSHELL_VERSION=v0.1.6 sh
```

The gateway Route is TLS passthrough serving a private CA, and OIDC discovery
uses the ingress CA. Trust both paths before adding the gateway.

Copy the gateway server CA into the CLI's per-gateway TLS directory. The
directory name must match the `--name` value you use below:

```shell
mkdir -p "$HOME/.config/openshell/gateways/openshell-team/mtls"
oc -n openshell-team get secret openshell-client-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 -d \
  > "$HOME/.config/openshell/gateways/openshell-team/mtls/ca.crt"
```

OIDC bearer authentication needs only `ca.crt` in this directory.

Build an `SSL_CERT_FILE` bundle from the system roots plus the ingress CA.
Setting `SSL_CERT_FILE` replaces the default bundle, so never point it at the
ingress CA alone:

```shell
cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
  "$HOME/.config/openshell-rhoai/ingress-ca.crt" \
  > "$HOME/.config/openshell-rhoai/ca-bundle.pem"
export SSL_CERT_FILE="$HOME/.config/openshell-rhoai/ca-bundle.pem"
```

On Debian-based hosts, replace the system bundle path with
`/etc/ssl/certs/ca-certificates.crt`. You may also source the ingress CA from
the installer-created ConfigMap:

```shell
oc -n openshell-team get configmap openshell-oidc-ca \
  -o jsonpath='{.data.ca\.crt}' > "$HOME/.config/openshell-rhoai/ingress-ca.crt"
```

Register the gateway:

```shell
openshell gateway add \
  --name openshell-team \
  --oidc-issuer "https://keycloak.apps.example.com/realms/openshell" \
  --oidc-client-id openshell-cli \
  --oidc-audience openshell-api-openshell-team \
  "https://gateway-openshell-team.apps.example.com:443"
```

Replace the issuer and hosts with the values in your configuration. The command
opens a browser for the Authorization Code + PKCE login.

Log in as a user that holds the gateway's admin role, configured in
`oidc.admin_role` and named `openshell-admin` in the Keycloak examples. The
admin role can create sandboxes and workspaces, and add users that hold the
user role (`oidc.user_role`, `openshell-user` in the Keycloak examples) to
workspaces.

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

The installer deploys the dashboard beside the gateway and prints its URL. You
can also use `https://<dashboard.host>` from your configuration. Open the URL
and sign in through the configured OIDC provider.

The dashboard shows different features depending on the signed-in user's role.
The account must hold a role listed in `oidc.allowed_roles`; the Keycloak
examples list `openshell-admin` and `openshell-user`. A user with the admin role
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
`openshell-installer` state and needs an explicit identity migration.

A changed client secret or OIDC CA requires explicit rotation. Update the
Secret while preserving `cookie-secret`, then restart the dashboard:

```shell
COOKIE=$(oc -n openshell-team get secret openshell-dashboard-oidc -o jsonpath='{.data.cookie-secret}' | base64 -d)
oc -n openshell-team create secret generic openshell-dashboard-oidc \
  --from-literal=client-secret="$(cat "$HOME/.config/openshell-rhoai/dashboard-client-secret.txt")" \
  --from-literal=cookie-secret="$COOKIE" \
  --dry-run=client -o yaml | oc apply -f -
oc -n openshell-team rollout restart deployment openshell-dashboard
```

There is no cross-release transaction or automatic rollback: a gateway success
followed by a dashboard failure leaves the upgraded gateway in place.

## Remove an installation

The installer has no uninstall subcommand. Remove the dashboard first, then the
gateway:

```shell
helm uninstall openshell-dashboard -n openshell-team --kube-context YOUR_CONTEXT
helm uninstall openshell -n openshell-team --kube-context YOUR_CONTEXT
```

The gateway chart's certificate hook creates three Secrets outside the release
manifest, so `helm uninstall` does not remove them. Delete them and the
installer-owned authentication objects:

```shell
oc -n openshell-team delete secret \
  openshell-server-tls openshell-client-tls openshell-jwt-keys
oc -n openshell-team delete secret openshell-dashboard-oidc
oc -n openshell-team delete configmap openshell-oidc-ca
```

Optionally delete the installer state ConfigMap and the namespace:

```shell
oc -n openshell-team delete configmap openshell-installer
oc delete namespace openshell-team
```

Remaining Secrets block a later reinstall and can be reused by a new gateway if
you keep the same names. PersistentVolumeClaims are not deleted by any of these
commands; inspect and remove them deliberately. The installer never deletes the
namespace for you.

## Troubleshoot common failures

| Symptom | Cause and fix |
|---|---|
| `oidc.client_secret_file is required for the first install` | Create the client secret file before `--check`, or reuse installer state from an earlier successful install. |
| No default StorageClass | Mark a block-backed StorageClass as default; the gateway's SQLite PVC needs it. |
| Agent Sandbox readiness fails | Install or start the Agent Sandbox controller, or override `agent_sandbox_namespace` and `agent_sandbox_deployment`. |
| `x509` error during `openshell gateway add` | Distinguish the two trust paths: copy the gateway CA into the CLI mtls directory, and build the `SSL_CERT_FILE` bundle for OIDC discovery. |
| `dns error` from `openshell status` after `gateway add` succeeds | The gateway host is outside the router's `*.apps.<domain>` wildcard, so it has no DNS record. Registration only contacts the OIDC issuer; `status` is the first gateway connection. Correct `gateway.host`, and reinstall when the installer already recorded the old host. |
| HTTP 403 after login | The user holds no role in `allowed_roles`. Add a listed role to the user, or include the roles the provider emits, then rerun the install command. |
| Gateway host or issuer change is rejected | The installer state records the original identity. Migrate the certificate and endpoint explicitly instead of editing state. |

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
