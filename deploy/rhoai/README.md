# Install OpenShell on OpenShift

OpenShell provides sandboxed runtimes for AI agents, and the Dashboard is its
web UI for managing workspaces and sandboxes.

`install.py` installs the OpenShell gateway and Dashboard into an OpenShift
namespace using Helm. This guide uses the RHOAI 3.6 image pins and PostgreSQL
configuration in `config-examples/config.example-rhoai-3.6-postgresql-keycloak.json`.

The installer is an interim tool until an OpenShift Operator deploys OpenShell.
It first ships with RHOAI 3.6 GA. Rerunning it against an existing installation
works only for installations made with the RHOAI 3.6 GA version or later.
The installer refuses installations made with earlier development versions,
or asks for `--adopt-existing`; reinstall those into a new namespace. To move
an installation to newer releases, see
[Upgrade an installation](#upgrade-an-installation).

## Prerequisites

- OpenShift 4.20 or newer on amd64 nodes, with the Red Hat Build of Agent
  Sandbox Operator installed and the default OVN-Kubernetes network plugin.
- A default StorageClass for sandbox workspace volumes.
- `uv`, Helm 3.17.3 or newer, and `kubectl` on the machine running
  the installer. That machine needs access to the OpenShift API and to the
  gateway and Dashboard chart registries, `ghcr.io` and `quay.io`.
- Cluster nodes must be able to pull the configured images. RHOAI images from
  `registry.redhat.io` require cluster pull credentials. For disconnected
  clusters, see [Disconnected clusters](#disconnected-clusters) for image
  mirroring guidance.
- A PostgreSQL database reachable from the OpenShell namespace, and an OIDC
  provider reachable from the workloads and users, with a confidential browser
  client using PKCE S256. The example uses Keycloak and PostgreSQL. For a
  development Keycloak deployment, follow the
  [Keycloak development guide](keycloak-dev-guide.md).
- Permission to create resources in the target namespace and read the cluster
  ingress domain, unless you set both hosts explicitly in the config.

The installer does not install the Agent Sandbox Operator, provision a database,
or deploy an identity provider.

Choose one installation method below: `install.py` automates chart values,
Secrets, and preflight; the direct Helm path requires you to prepare them.

## Install with `install.py`

### Configure

From the repository root, copy the example and its credential files outside
the checkout:

```shell
export CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openshell-rhoai"
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
cp deploy/rhoai/config-examples/config.example-rhoai-3.6-postgresql-keycloak.json \
  "$CONFIG_DIR/config.json"
chmod 600 "$CONFIG_DIR/config.json"
```

Edit `config.json` before installing:

- Set `namespace` to the OpenShell namespace you will use.
- Set `oidc.issuer` to your provider's issuer URL. The example uses
  `https://keycloak.apps.example.com/realms/openshell`.
- Register `https://dashboard-<namespace>.<apps-domain>/oauth2/callback` as
  the browser client's callback URL. The example's client ID, audience, role
  claim, and role names match the Keycloak development guide; keep them aligned
  with your provider.
- The example pins RHOAI 3.6 images by digest. For another RHOAI build, use the
  image digests for that build.

Save the browser client secret in the file named by `oidc.client_secret_file`
(`dashboard-client-secret.txt` in the example):

```shell
umask 077
read -rsp 'OIDC client secret: ' OIDC_SECRET
printf '\n'
printf '%s' "$OIDC_SECRET" > "$CONFIG_DIR/dashboard-client-secret.txt"
unset OIDC_SECRET
chmod 600 "$CONFIG_DIR/dashboard-client-secret.txt"
```

For an existing PostgreSQL database, save its URI in the file named by
`gateway.database.uri_file` (`gateway-db-uri.txt`). If you want to run a
development database in the OpenShell namespace, skip this and use the next
section, which creates the file for you.

```shell
umask 077
read -rsp 'PostgreSQL URI: ' DB_URI
printf '\n'
printf '%s' "$DB_URI" > "$CONFIG_DIR/gateway-db-uri.txt"
unset DB_URI
chmod 600 "$CONFIG_DIR/gateway-db-uri.txt"
```

Use a URI such as
`postgresql://user:password@host:5432/database?sslmode=verify-full`. Keep the
database password out of `config.json`. Without `sslmode`, the gateway uses
TLS only when the server offers it and does not verify the certificate. With
`verify-full`, the server certificate must chain to a CA in the gateway
image's system trust store. The installer does not mount a separate database
CA, so a database signed by a private CA cannot use `verify-full` yet;
`sslmode=require` encrypts the connection but does not verify the server.

The database outlives the namespace. The gateway encrypts stored provider
credentials with the key in the `openshell-credential-storage-key-encryption-key`
Secret, so back up that Secret together with the database (see
[Upgrade an installation](#upgrade-an-installation)). If you reinstall into a
recreated namespace with the same name against the same database, create the
namespace, restore the Secret with
`oc apply -f "$CONFIG_DIR/key-encryption-key-secret.json"`, and run the
installer with `--adopt-existing`: the
restored key counts as existing key material, and deleting it as the
installer's error suggests makes the chart generate a new key that cannot
decrypt the stored credentials.

The Keycloak development guide uses the cluster's default ingress certificate.
For that setup, create the CA file referenced by `oidc.ca_file` in the example:

```shell
oc -n openshift-config-managed get configmap default-ingress-cert \
  -o jsonpath='{.data.ca-bundle\.crt}' > "$CONFIG_DIR/ingress-ca.crt"
```

For an issuer with a publicly trusted certificate, remove `ca_file` from the
config instead.

### Set up PostgreSQL for development

For development, you can run PostgreSQL in the OpenShell namespace. This
single-instance database is not a production setup. Set `NS` to the namespace
in `config.json` and use the `CONFIG_DIR` from above:

```shell
export NS=openshell-team
if ! oc get namespace "$NS" >/dev/null 2>&1; then
  oc create namespace "$NS" &&
    oc label namespace "$NS" openshell.ai/installer=odh-dashboard
fi
```

The label marks the new, empty namespace as created for the installer, so
reruns do not need `--adopt-existing`. Do not add it to a namespace that
already existed; see
[Reinstalling into an existing namespace](#reinstalling-into-an-existing-namespace).

Create a password Secret and a persistent volume claim:

```shell
openssl rand -hex 16 | tr -d '\n' | \
  oc -n "$NS" create secret generic openshell-db-secret \
    --from-literal=username=openshell --from-file=password=/dev/stdin

oc -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openshell-db-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
EOF
```

Create the database Deployment and Service from the Red Hat PostgreSQL image,
then add the password Secret and persistent storage:

```shell
oc -n "$NS" new-app \
  registry.access.redhat.com/hi/postgresql@sha256:67599d73c3dae0e8685c2f9ba31c11028477816bbc254cf862543cfb11c2dc3f \
  -e POSTGRES_USER=openshell \
  -e POSTGRES_DATABASE=openshell \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  --name=openshell-db

oc -n "$NS" patch deployment/openshell-db --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"POSTGRES_PASSWORD","valueFrom":{"secretKeyRef":{"name":"openshell-db-secret","key":"password"}}}}]'
oc -n "$NS" set volume deployment/openshell-db \
  --add --overwrite --name=openshell-db-volume-1 \
  --type=persistentVolumeClaim --claim-name=openshell-db-data \
  --mount-path=/var/lib/postgresql
oc -n "$NS" rollout status deployment/openshell-db
```

If the image version uses a different volume name, inspect the Deployment and
use its volume name with `oc set volume`. Once PostgreSQL is ready, create the
URI file used by the installer without printing the password:

```shell
umask 077
DB_PASSWORD="$(oc -n "$NS" get secret openshell-db-secret \
  -o jsonpath='{.data.password}' | base64 -d)"
printf 'postgresql://openshell:%s@openshell-db.%s.svc.cluster.local:5432/openshell' \
  "$DB_PASSWORD" "$NS" > "$CONFIG_DIR/gateway-db-uri.txt"
unset DB_PASSWORD
chmod 600 "$CONFIG_DIR/gateway-db-uri.txt"
```

The installer copies this URI into its gateway Secret; it does not create or
validate the database. If the namespace has default-deny egress policies, allow
the gateway to reach the database Service on port 5432.

### Run the installer

Validate the chart templates, then check cluster prerequisites:

```shell
./deploy/rhoai/install.py --config "$CONFIG_DIR/config.json" --check
./deploy/rhoai/install.py --config "$CONFIG_DIR/config.json" --preflight
```

Install:

```shell
./deploy/rhoai/install.py --config "$CONFIG_DIR/config.json"
```

Pass `--context CONTEXT` to target a kubeconfig context other than the current
one, or `--namespace NAME` to override the configured namespace. The installer
prints the gateway and Dashboard URLs and the next steps for registering the
gateway with the OpenShell CLI.

### Reinstalling into an existing namespace

When the namespace already exists and holds installer state (the
`openshell-installer` ConfigMap) or gateway key material
(`openshell-server-tls`, `openshell-client-tls`, `openshell-jwt-keys`,
`openshell-credential-storage-key-encryption-key`, `openshell-dashboard-oidc`),
the installer reuses it only when the namespace proves the installer created
the deployment: the Namespace carries the `openshell.ai/installer:
odh-dashboard` label and the installer state is present. The installer sets the
label when it creates the namespace. Namespace editors cannot set it on a
namespace they do not administer, so the installer does not trust the ConfigMap
label alone.

Do not add the label to a namespace that other users could already write to,
such as an existing Data Science Project: anyone with edit access could have
planted these objects, and the gateway would reuse their keys. Instead, inspect
the listed objects and pass `--adopt-existing` only if they come from a
previous installation of this gateway; otherwise delete them first.

## Install directly with Helm

Use this alternative when you want to manage the gateway and Dashboard Helm
releases yourself. The configuration and PostgreSQL sections above still
apply, but Helm does not create the database, credentials, issuer CA ConfigMap,
or validate the cluster prerequisites for you.

Set `NS` to the target namespace. Use the same namespace and Route hosts in the
values files below, and register the Dashboard callback URL with your OIDC
provider:

```shell
export NS=openshell-team
oc get namespace "$NS" >/dev/null 2>&1 || oc create namespace "$NS"
```

Create the Secrets consumed by the charts. The gateway Secret needs a `uri`
key; the Dashboard Secret needs `client-secret` and `cookie-secret` keys:

```shell
oc -n "$NS" create secret generic openshell-gateway-db \
  --from-file=uri="$CONFIG_DIR/gateway-db-uri.txt"

openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' \
  > "$CONFIG_DIR/dashboard-cookie-secret.txt"
chmod 600 "$CONFIG_DIR/dashboard-cookie-secret.txt"
oc -n "$NS" create secret generic openshell-dashboard-oidc \
  --from-file=client-secret="$CONFIG_DIR/dashboard-client-secret.txt" \
  --from-file=cookie-secret="$CONFIG_DIR/dashboard-cookie-secret.txt"
```

If the OIDC issuer uses a private CA, create the ConfigMap referenced by both
charts. Omit `caConfigMapName` from both values files below when the issuer is
publicly trusted:

```shell
oc -n "$NS" create configmap openshell-oidc-ca \
  --from-file=ca.crt="$CONFIG_DIR/ingress-ca.crt"
```

Create `gateway-values.yaml` and `dashboard-values.yaml` in `$CONFIG_DIR`. Set
the OIDC fields and hosts to match your provider and Routes. These values show
the Keycloak development guide defaults:

```yaml
# gateway-values.yaml
fullnameOverride: openshell
podSecurityContext: null
securityContext:
  runAsUser: null
  seccompProfile:
    type: RuntimeDefault
workload:
  kind: deployment
server:
  disableTls: false
  sandboxNamespace: openshell-team
  auth:
    allowUnauthenticatedUsers: false
  tls:
    enableMtls: false
    clientCaSecretName: ""
    certSecretName: openshell-server-tls
    clientTlsSecretName: openshell-client-tls
  externalDbSecret: openshell-gateway-db
  oidc:
    issuer: https://keycloak.apps.example.com/realms/openshell
    audience: openshell-api-openshell-team
    rolesClaim: realm_access.roles
    adminRole: openshell-admin
    userRole: openshell-user
    caConfigMapName: openshell-oidc-ca
pkiInitJob:
  enabled: true
  serverDnsNames:
    - gateway-openshell-team.apps.example.com
    - openshell.openshell-team.svc
    - openshell.openshell-team.svc.cluster.local
openshiftRoute:
  enabled: true
  host: gateway-openshell-team.apps.example.com
```

```yaml
# dashboard-values.yaml
fullnameOverride: openshell-dashboard
podSecurityContext: null
securityContext:
  runAsUser: null
  seccompProfile:
    type: RuntimeDefault
gateway:
  url: grpcs://openshell.openshell-team.svc.cluster.local:8080
  caSecretName: openshell-client-tls
oidc:
  provider: keycloak-oidc
  issuer: https://keycloak.apps.example.com/realms/openshell
  clientId: openshell-dashboard-openshell-team
  existingSecret: openshell-dashboard-oidc
  audience: openshell-api-openshell-team
  rolesClaim: realm_access.roles
  adminRole: openshell-admin
  userRole: openshell-user
  codeChallengeMethod: S256
  allowedRoles: [openshell-admin, openshell-user]
  caConfigMapName: openshell-oidc-ca
  scope: openid email profile
openshiftRoute:
  enabled: true
  host: dashboard-openshell-team.apps.example.com
  termination: edge
networkPolicy:
  ingressNamespace: openshift-ingress
```

For a publicly trusted issuer, remove `caConfigMapName` from both values
files. For the RHOAI images in the example config, copy each `registry`,
`repository`, and `digest` into the corresponding chart image values:

| Installer config field          | Helm values path                                    |
| ------------------------------- | --------------------------------------------------- |
| `gateway.images.gateway`        | `gateway.image`                                     |
| `gateway.images.supervisor`     | `supervisor.image`                                  |
| `gateway.images.sandboxRuntime` | `sandboxRuntime.image`                              |
| `gateway.images.sandbox`        | `sandbox.image` (`repository` is a full image path) |
| `dashboard.images.dashboard`    | `dashboard.image`                                   |
| `dashboard.images.authProxy`    | `authProxy.image`                                   |

Install the gateway first so it creates the TLS Secrets used by the Dashboard,
then install the Dashboard:

```shell
helm upgrade --install openshell \
  oci://ghcr.io/nvidia/openshell/helm-chart --version 0.1.3 \
  --namespace "$NS" --values "$CONFIG_DIR/gateway-values.yaml" \
  --wait --wait-for-jobs --timeout 15m

helm upgrade --install openshell-dashboard \
  oci://quay.io/ai-openshell/charts/console --version 0.1.5 \
  --namespace "$NS" --values "$CONFIG_DIR/dashboard-values.yaml" \
  --wait --timeout 15m
```

The values shown target the example's chart versions and namespace. If you
change either version or the namespace, update the chart versions, image pins,
OIDC identifiers, Service URL, and certificate DNS names together. For other
chart options, see the [gateway chart values](../helm/openshell/values.yaml)
and inspect the Dashboard chart values with
`helm show values oci://quay.io/ai-openshell/charts/console --version 0.1.5`.

## After installation: install the CLI and create a sandbox

Install the CLI version that matches the gateway chart version. This example
uses `0.1.3`:

```shell
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh \
  | OPENSHELL_VERSION=v0.1.3 sh
```

The upstream installer also starts a separate local gateway on this machine;
the commands below use the gateway deployed in OpenShift. On a disconnected
workstation, bring over the matching CLI binary instead.

Set `NS` to the installed namespace and `CTX` to the kubeconfig context used
during installation (`--context`, or the current context if omitted). Copy the
gateway CA into the CLI's per-gateway trust directory:

```shell
export NS=openshell-team
export CTX=YOUR_INSTALL_CONTEXT
GATEWAY_MTLS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/$NS/mtls"
mkdir -p "$GATEWAY_MTLS_DIR"
oc --context "$CTX" -n "$NS" get secret openshell-client-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "$GATEWAY_MTLS_DIR/ca.crt"
```

If `oidc.ca_file` is set for a private or self-signed identity provider,
combine that CA with the workstation's system CA bundle and set
`SSL_CERT_FILE`. This example uses the Fedora/RHEL bundle path; use the path
reported by the installer on other systems:

```shell
cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
  "$CONFIG_DIR/ingress-ca.crt" > "$CONFIG_DIR/ca-bundle.pem"
export SSL_CERT_FILE="$CONFIG_DIR/ca-bundle.pem"
```

Register the gateway, replacing the example OIDC values and URL with those in
`config.json` and the URL printed by the installer. The CLI client ID defaults
to `openshell-cli-<namespace>` if `oidc.cli_client_id` is not set:

```shell
openshell gateway add \
  --name "$NS" \
  --oidc-issuer "https://keycloak.apps.example.com/realms/openshell" \
  --oidc-client-id "openshell-cli-$NS" \
  --oidc-audience "openshell-api-$NS" \
  "https://gateway-openshell-team.apps.example.com:443"
openshell status
```

Sign in with an identity that has the configured admin or user role and access
to a workspace. The CLI uses the `default` workspace unless you select another
one with `--workspace` or `OPENSHELL_WORKSPACE`.

Create a sandbox:

```shell
openshell sandbox create
```

The gateway assigns the sandbox a name and opens a shell. Exit with Control+D
to leave it running; use `openshell sandbox list` and
`openshell sandbox connect <name>` to return to it.

## Upgrade an installation

To move an installation to newer OpenShell releases, rerun the installer with a
configuration that pins the new chart versions and images. The installer runs
`helm upgrade` on both releases and keeps the gateway's TLS, JWT, and
credential-storage keys. It does not compare the old and new versions, so it
does not stop a downgrade or an untested version pair; check the release notes
before you change versions.

Copy your current `config.json` and change only `gateway.chart`,
`gateway.version`, `dashboard.chart`, `dashboard.version`, and the `images`
pins, for example from a newer file in `config-examples/`. Keep the namespace,
hosts, `oidc` settings, `gateway.database.mode`, and the client secret and
database URI files. The installer refuses a change to the hosts, the OIDC
issuer, audience, or client ID, or the database backend, and it refuses secret
files that differ from the Secrets in the namespace.

The new gateway migrates the database schema when it starts, and an older
gateway cannot start against the migrated schema. Before you upgrade, back up
the database with your database's tooling, and save the key-encryption key
Secret, without which the provider credentials in the backup cannot be
decrypted. This command requires `jq`:

```shell
umask 077
oc -n "$NS" get secret openshell-credential-storage-key-encryption-key -o json \
  | jq 'del(.metadata.uid, .metadata.resourceVersion,
            .metadata.creationTimestamp, .metadata.managedFields)' \
  > "$CONFIG_DIR/key-encryption-key-secret.json"
```

For the development database from
[Set up PostgreSQL for development](#set-up-postgresql-for-development):

```shell
oc -n "$NS" exec deployment/openshell-db -- \
  pg_dump -U openshell openshell > "$CONFIG_DIR/openshell-db.sql"
```

In SQLite mode the data lives in the gateway's persistent volume claim; back it
up with your storage tooling instead.

Store the backups somewhere safe; the Secret file contains the key in clear
text. Then validate and upgrade:

```shell
./deploy/rhoai/install.py --config "$CONFIG_DIR/config-new.json" --check
./deploy/rhoai/install.py --config "$CONFIG_DIR/config-new.json" --preflight
./deploy/rhoai/install.py --config "$CONFIG_DIR/config-new.json"
```

After the upgrade:

- Install the CLI version that matches the new gateway chart version, as in
  [After installation](#after-installation-install-the-cli-and-create-a-sandbox).
- Existing sandboxes keep their supervisor and sandbox images until they are
  recreated. Create a new sandbox to check the new images, and check that the
  existing sandboxes still respond.

You cannot roll back in place. To return to the previous versions, restore the
database backup into an empty database, then rerun the installer with the
previous configuration.

## Disconnected clusters

The machine running `install.py` or Helm pulls the charts; cluster nodes pull
the container images. When that machine can reach `ghcr.io` and `quay.io`, the
charts do not need to be mirrored. Mirror the images to a registry reachable by
the cluster, then point the installer config or direct Helm image values at
that mirror while retaining each image digest. The example includes the
gateway, supervisor, sandbox runtime, Dashboard, and oauth2-proxy images.

For example, copy each source image by digest to a tag in your mirror:

```shell
oc image mirror \
  registry.redhat.io/rhoai/odh-openshell-gateway-rhel9@sha256:<digest> \
  registry.example.com/rhoai/odh-openshell-gateway-rhel9:rhoai-3.6
```

Repeat for the image repositories and digests in the config. Set the matching
`registry` and `repository` fields to `registry.example.com` and the mirrored
repository; `gateway.images.sandbox.repository` is a full image path and should
also point to the mirror. Keep the digest in the config. `install.py` warns,
from `--check` onward, about every rendered image that is not pinned by digest,
including chart defaults such as the oauth2-proxy image. Ensure the cluster can
authenticate to the mirror. Use the RHOAI operator CSV to get the image digests
for the build installed in your cluster:

```shell
oc get csv rhods-operator.3.6.0 -n redhat-ods-operator -o yaml | grep -A1 OPENSHELL
```

The Red Hat build of Agent Sandbox installation guide covers OperatorHub
installation, but does not document disconnected installation. For a
disconnected cluster, use OpenShift's [Operator Lifecycle Manager guide for
disconnected environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/olm-restricted-networks) and [`oc-mirror` v2 ImageSetConfiguration reference](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/about-installing-oc-mirror-v2)
to mirror the Agent Sandbox Operator package and channel from the Red Hat
Operator catalog matching the cluster's OpenShift version, including its
bundle and related images. Install the Operator from the generated mirrored
catalog using **All namespaces on the cluster** and `agent-sandbox-system` as
the installed namespace, as described in the [Agent Sandbox Operator
installation procedure](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/install-agent-sandbox-overview_agent-sandbox).

If the machine installing the charts cannot reach the chart registries either,
mirror both charts and point the installer config or direct Helm commands at
their mirrored OCI URLs. The host running `install.py` also needs the
installer's pinned PyYAML dependency available to `uv`. For example:

```shell
helm pull oci://ghcr.io/nvidia/openshell/helm-chart --version 0.1.3
helm push openshell-0.1.3.tgz oci://registry.example.com/charts
helm pull oci://quay.io/ai-openshell/charts/console --version 0.1.5
helm push console-0.1.5.tgz oci://registry.example.com/charts
```

Log the installer machine in to the mirror with
`helm registry login registry.example.com`. Use the chart versions set in your
config when pulling the charts.

## Troubleshooting

| Symptom                                                              | What to check                                                                                                                                                               |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--check` reports a missing client secret or database URI            | Create the files named by `oidc.client_secret_file` and `gateway.database.uri_file`. Their paths are relative to `config.json`.                                             |
| Preflight cannot find the Agent Sandbox controller or a StorageClass | Install the operator and confirm a default class is available for workspace volumes.                                                                                        |
| The gateway is not ready                                             | Inspect `oc -n <namespace> logs deployment/openshell` and check the PostgreSQL URI, credentials, network access, and any egress policy.                                     |
| OIDC login fails or reports an `x509` error                          | Confirm `oidc.issuer`, the browser callback URL, and the client settings. For a private or self-signed issuer certificate, configure `oidc.ca_file` as described above.     |
| Pods show `ImagePullBackOff`                                         | Confirm each image is present in the mirror, the config points to the mirror with the correct digest, and the cluster can authenticate to it.                               |
| Helm cannot pull a chart                                             | The machine running `install.py` or Helm must reach `ghcr.io` and `quay.io`, or the charts must be mirrored and their URLs updated in the installer config or Helm command. |

## Related guide

- [Keycloak development guide](keycloak-dev-guide.md): deploy Keycloak for
  development and configure its OpenShell clients.
