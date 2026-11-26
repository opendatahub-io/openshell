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
[Upgrade an installation](#upgrade-an-installation); to remove it, see
[Uninstall](#uninstall).

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
- Permission to create resources in the target namespace. Cluster-scoped
  permission to create namespaces when the installer creates it, read the
  Namespace object, the Agent Sandbox CRD, the ClusterVersion, StorageClasses,
  and Nodes, create and patch ClusterRoles and ClusterRoleBindings, and list
  ConfigMaps in all namespaces. When the target namespace already exists,
  preflight also reads its ConfigMaps and Secrets. The installer also reads the
  cluster ingress domain unless you set both hosts explicitly in the config.
  Preflight checks the write permissions with `oc auth can-i` and fails on a
  denied read.

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
database URI files. The installer refuses a change to the gateway host, the
OIDC issuer, audience, or client ID, or the database backend, and it refuses
secret files that differ from the Secrets in the namespace. It accepts a
dashboard host change, but re-register the dashboard callback URL with the
identity provider first.

The new gateway migrates the database schema when it starts, and an older
gateway cannot start against the migrated schema. Before you upgrade, back up
the database with your database's tooling, and save the key-encryption key
Secret, without which the provider credentials in the backup cannot be
decrypted. Run the backup and upgrade commands in the kubeconfig context you
installed into; the installer's `--context` is not remembered.

Set `NS` to the installed namespace and `CONFIG_DIR` to the directory that
holds your configuration and credential files:

```shell
export NS=openshell-team
export CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openshell-rhoai"
```

This command requires `jq`:

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

## Uninstall

Uninstalling deletes the sandboxes, the gateway's keys, and in SQLite mode the
gateway data. To reinstall later with the same data, back up the database and
the key-encryption key Secret first, as described in
[Upgrade an installation](#upgrade-an-installation).

The commands in this section use the current kubeconfig context. Select the
context you installed into first if you used `--context`; `$NS` can also exist
in another cluster.

Set `NS` to the installed namespace and `CONFIG_DIR` to the directory that
holds your configuration and credential files:

```shell
export NS=openshell-team
export CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openshell-rhoai"
```

While the gateway is still running, delete the sandboxes in each workspace and
remove the CLI registration:

```shell
openshell workspace list
openshell sandbox delete --all --workspace <workspace>
openshell gateway remove "$NS"
```

Uninstall both releases. This also removes the gateway's cluster-scoped RBAC,
which deleting the namespace alone would leave behind:

```shell
helm uninstall openshell-dashboard -n "$NS"
helm uninstall openshell -n "$NS"
```

Helm keeps the objects that the installer created and the key material the
gateway chart reuses on reinstall. If the installer created the namespace for
this deployment, delete the namespace. This also removes the development
PostgreSQL database if you deployed it there:

```shell
oc delete namespace "$NS"
```

In a namespace that also holds other workloads, delete the remaining objects
and the ownership label instead:

```shell
oc -n "$NS" delete configmap openshell-installer openshell-oidc-ca --ignore-not-found
oc -n "$NS" delete secret openshell-gateway-db openshell-dashboard-oidc \
  openshell-server-tls openshell-client-tls openshell-jwt-keys \
  openshell-credential-storage-key-encryption-key --ignore-not-found
oc -n "$NS" delete pvc openshell-data-openshell-0 --ignore-not-found
oc label namespace "$NS" openshell.ai/installer-
```

For the development database, also run:

```shell
oc -n "$NS" delete all -l app=openshell-db
oc -n "$NS" delete pvc openshell-db-data
oc -n "$NS" delete secret openshell-db-secret
```

Check `oc -n "$NS" get pvc` for leftover sandbox workspace claims.

The installer does not manage an external database or the identity provider:
drop the OpenShell database with your database's tooling, and remove the OIDC
clients as described in the [Keycloak development guide](keycloak-dev-guide.md#cleanup).

Delete `$CONFIG_DIR` when you no longer need it; it holds the client secret and the
database URI.

## Disconnected clusters

Skip this section if your cluster nodes can pull from `registry.redhat.io` and
`registry.access.redhat.com`, and the machine running `install.py` can reach
`ghcr.io` and `quay.io`.

Otherwise, mirror the images with the [`oc-mirror` plugin v2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/disconnected_environments/about-installing-oc-mirror-v2), which also creates the `ImageDigestMirrorSet` (IDMS) that redirects pulls to your mirror.

IDMS redirects digest references only, so the configuration must pin every image by digest, as the RHOAI example does. `install.py` warns about any rendered image without a digest. Complete this section before installing.

### What to mirror

- The gateway, supervisor, sandbox, and Dashboard images from
  `registry.redhat.io/rhoai`. If you mirrored OpenShift AI as described in
  [Deploy OpenShift AI in a disconnected environment](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html-single/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/index#deploying-openshift-ai-in-a-disconnected-environment_install),
  they are already in your mirror as related images of the operator. To
  confirm:

  ```shell
  oc get csv rhods-operator.3.6.0 -n redhat-ods-operator \
    -o jsonpath='{range .spec.relatedImages[*]}{.image}{"\n"}{end}' | grep openshell
  ```

- The Dashboard's oauth2-proxy image, `registry.access.redhat.com/hi/oauth2-proxy`.
  It is not part of OpenShift AI.

- Any other sandbox image that users pass to `openshell sandbox create --from`.
  Mirror it, make sure an IDMS covers its repository, and reference it by
  digest, for example `--from quay.io/example/agent@sha256:<digest>`.

Add the images that are not mirrored yet, by digest, to the `additionalImages`
of your `ImageSetConfiguration`. Then mirror the image set and apply the
generated cluster resources, as described in the `oc-mirror` guide.

### ImageDigestMirrorSet entries

List the image sources your cluster already redirects:

```shell
oc get imagedigestmirrorset \
  -o jsonpath='{range .items[*].spec.imageDigestMirrors[*]}{.source}{"\n"}{end}' | sort -u
```

The list must include `registry.redhat.io/rhoai`,
`registry.access.redhat.com/hi`, and the repositories of any other sandbox
images. The Machine Config Operator rolls an IDMS out to every node without
rebooting it, and also drains the nodes when you change an existing IDMS; see
[image registry repository mirroring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/images/image-configuration-classic). Wait until `oc get mcp` shows `UPDATED=True` for every pool before installing. The cluster pull secret must include credentials for the mirror.

### Agent Sandbox Operator

Mirror the Agent Sandbox Operator package from the Red Hat Operator catalog
for your OpenShift version, as described in
[Using Operator Lifecycle Manager in disconnected environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/olm-restricted-networks).
Then install it from the mirrored catalog with **All namespaces on the
cluster** and `agent-sandbox-system` as the installed namespace, following the
[Agent Sandbox Operator installation procedure](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/install-agent-sandbox-overview_agent-sandbox).

### OpenShell Charts

If the machine running `install.py` cannot reach `ghcr.io` and `quay.io`, log
in to the mirror registry with `helm registry login registry.example.com`,
then push both charts to an OCI registry it can reach, using the chart versions
in your configuration, and set `gateway.chart` and `dashboard.chart` to the
mirrored URLs:

```shell
helm pull oci://ghcr.io/nvidia/openshell/helm-chart --version 0.1.3
helm push helm-chart-0.1.3.tgz oci://registry.example.com/charts
helm pull oci://quay.io/ai-openshell/charts/console --version 0.1.5
helm push console-0.1.5.tgz oci://registry.example.com/charts
```

The machine also needs the installer's pinned PyYAML dependency available to
`uv`.

## Troubleshooting

| Symptom                                                              | What to check                                                                                                                                                                                                           |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--check` reports a missing client secret or database URI            | Create the files named by `oidc.client_secret_file` and `gateway.database.uri_file`. Their paths are relative to `config.json`.                                                                                         |
| Preflight cannot find the Agent Sandbox controller or a StorageClass | Install the operator and confirm a default class is available for workspace volumes.                                                                                                                                    |
| The gateway is not ready                                             | Inspect `oc -n <namespace> logs deployment/openshell` for PostgreSQL or `statefulset/openshell` for SQLite, and check the PostgreSQL URI, credentials, network access, and any egress policy.                            |
| OIDC login fails or reports an `x509` error                          | Confirm `oidc.issuer`, the browser callback URL, and the client settings. For a private or self-signed issuer certificate, configure `oidc.ca_file` as described above.                                                 |
| Pods show `ImagePullBackOff`                                         | On a disconnected cluster, confirm the image is in the mirror, an IDMS covers its repository, the configuration pins it by digest, the Machine Config Pool update finished, and the pull secret has mirror credentials. |
| Helm cannot pull a chart                                             | The machine running `install.py` or Helm must reach `ghcr.io` and `quay.io`, or the charts must be mirrored and their URLs updated in the installer config or Helm command.                                             |

## Related guide

- [Keycloak development guide](keycloak-dev-guide.md): deploy Keycloak for
  development and configure its OpenShell clients.
