# Install Keycloak for OpenShell development on OpenShift

This guide is for development only and is not a production Keycloak
deployment: it runs one PostgreSQL instance and one Keycloak instance with
bootstrap credentials, and the client helper verifies the Keycloak Route
against the cluster ingress CA.

It deploys and removes a development Keycloak instance only. Use
[README.md](README.md) to install OpenShell and the OpenShell Dashboard admin UI.
Follow this guide first when you need a local identity provider; skip it when
your cluster already has an OIDC provider. On a cluster that cannot reach the
public registries, follow [Disconnected clusters: mirror the
images](#disconnected-clusters-mirror-the-images) first.

Set the environment used throughout the guide:

```shell
export APPS_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
export NS=openshell-team
export KEYCLOAK_NS=keycloak
export REALM=openshell
export API_ID="openshell-api-${NS}"
export DASH_ID="openshell-dashboard-${NS}"
export CLI_ID="openshell-cli-${NS}"
export DASH_URL="https://dashboard-${NS}.${APPS_DOMAIN}"
export KC_URL="https://keycloak.${APPS_DOMAIN}"
export CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/openshell-rhoai"
```

The client IDs are namespace-qualified and match the example configurations, so
the commands work unchanged for the default namespace. `DASH_URL` also matches
the host the installer derives from the namespace and ingress domain, so the
example configurations need no host changes. Changing `NS` changes the client
IDs, `DASH_URL`, and both derived hosts; update the OIDC identifiers in the
OpenShell configuration from [README.md](README.md) and re-register
`https://<new-dashboard-host>/oauth2/callback` with Keycloak. If the
configuration sets explicit hosts, register that dashboard URL instead.

Realm roles are realm-wide. In a shared realm, a user with `openshell-admin` is
an administrator for every gateway in that realm, regardless of the client IDs.
Use one realm per trust boundary when gateways serve different teams.

## Part 1: PostgreSQL and Keycloak

### Create the namespace and database secret

```shell
oc new-project "$KEYCLOAK_NS"
openssl rand -base64 24 | tr -d '\n' | \
  oc -n "$KEYCLOAK_NS" create secret generic keycloak-db-secret \
    --from-literal=username=keycloak --from-file=password=/dev/stdin
```

Reading the generated password from stdin keeps it out of the process argument
list.

### Deploy PostgreSQL with persistent storage

Create the claim:

```shell
oc -n "$KEYCLOAK_NS" apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: keycloak-db-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
EOF
```

Deploy PostgreSQL from the Red Hat hardened image, pinned by digest. The image
is public, so this also works on a connected cluster. Refresh the digest from
the `18.4` tag when you want a newer build:

```shell
skopeo inspect --format '{{.Digest}}' \
  docker://registry.access.redhat.com/hi/postgresql:18.4
oc -n "$KEYCLOAK_NS" new-app registry.access.redhat.com/hi/postgresql@sha256:67599d73c3dae0e8685c2f9ba31c11028477816bbc254cf862543cfb11c2dc3f \
  -e POSTGRES_USER=keycloak \
  -e POSTGRES_DATABASE=keycloak \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  --name=keycloak-db
```

The digest form matters on a disconnected cluster: an
`ImageDigestMirrorSet` rewrites digest pulls to the mirror registry but leaves
tag pulls pointed at the original registry, where they fail.

Do not pass the database password through `oc new-app`: it would appear in the
process table and as a literal Deployment value. Add the reference from
`keycloak-db-secret` instead:

```shell
oc -n "$KEYCLOAK_NS" patch deployment/keycloak-db --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"POSTGRES_PASSWORD","valueFrom":{"secretKeyRef":{"name":"keycloak-db-secret","key":"password"}}}}]'
```

Replace the image's emptyDir volume with the claim. The image names its volume
`keycloak-db-volume-1` at `/var/lib/postgresql`; inspect the Deployment if the
name differs in your image version:

```shell
oc -n "$KEYCLOAK_NS" set volume deployment/keycloak-db \
  --add --overwrite --name=keycloak-db-volume-1 \
  --type=persistentVolumeClaim \
  --claim-name=keycloak-db-data \
  --mount-path=/var/lib/postgresql
oc -n "$KEYCLOAK_NS" rollout status deployment/keycloak-db
```

### Install the Red Hat build of Keycloak Operator

Use either the console or a Subscription. In the console, open
**Operators** → **OperatorHub**, search for **Red Hat build of Keycloak**,
install it in the `keycloak` namespace or all namespaces, and wait until the
operator pod is ready:

```shell
oc -n "$KEYCLOAK_NS" rollout status deployment/rhbk-operator
```

If you installed the operator for all namespaces, its Deployment runs in
`openshift-operators`; use `-n openshift-operators` for that command instead.

To install with a Subscription instead, first list the channels your cluster
offers and pick a version channel from the output:

```shell
oc get packagemanifest rhbk-operator -n openshift-marketplace \
  -o jsonpath='{.status.channels[*].name}'
```

The manifests below use `stable-v26.6` and expand `KEYCLOAK_NS`. Channel names
change with operator releases, so substitute a channel from the command output
when needed.

```shell
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: ${KEYCLOAK_NS}
spec:
  channel: stable-v26.6
  installPlanApproval: Automatic
  name: rhbk-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

Apply an OperatorGroup only when the namespace does not already have one:

```shell
oc get operatorgroup -n "$KEYCLOAK_NS"
```

```shell
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${KEYCLOAK_NS}
  namespace: ${KEYCLOAK_NS}
spec:
  targetNamespaces:
    - ${KEYCLOAK_NS}
EOF
```

The Subscription installs asynchronously, and the Keycloak CRD may not exist
yet when the next command runs. Wait for the operator Deployment to become
ready before creating the instance:

```shell
oc -n "$KEYCLOAK_NS" rollout status deployment/rhbk-operator
```

### Create the Keycloak instance

```shell
oc -n "$KEYCLOAK_NS" apply -f - <<EOF
apiVersion: k8s.keycloak.org/v2beta1
kind: Keycloak
metadata:
  name: keycloak
  namespace: ${KEYCLOAK_NS}
spec:
  instances: 1
  db:
    vendor: postgres
    host: keycloak-db
    usernameSecret:
      name: keycloak-db-secret
      key: username
    passwordSecret:
      name: keycloak-db-secret
      key: password
  http:
    httpEnabled: true
  hostname:
    hostname: keycloak.${APPS_DOMAIN}
  proxy:
    headers: xforwarded
EOF
oc -n "$KEYCLOAK_NS" get keycloak keycloak -w
```

The `hostname` field makes the operator create and own an edge-terminated
Route for that host. Do not create a Route yourself; a manual Route collides
with the operator-managed hostname.

### Get the admin credentials

```shell
oc -n "$KEYCLOAK_NS" get route
echo "console:  ${KC_URL}/admin/"
echo "username: $(oc -n "$KEYCLOAK_NS" get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)"
echo "password: $(oc -n "$KEYCLOAK_NS" get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)"
```

The operator names the bootstrap administrator `temp-admin`, not `admin`. Log
in to the master realm with those credentials and create a permanent
administrator afterwards; the bootstrap credentials are temporary.

After the permanent administrator can log in, delete the bootstrap user:
**Users** → `temp-admin` → **Delete**. Leaving it in place keeps a well-known
development credential valid for the lifetime of the realm.

## Part 2: Realm configuration

Perform these steps in the Keycloak admin console unless a section says
otherwise. The command-line script in this part creates the realm, roles, and
clients; create the users in the console. When a Keycloak administrator already
created the registrations, use their values instead and skip the sections you
do not need.

The Keycloak console does not expand shell variables. Print the literal values
and enter them verbatim:

```shell
echo "API audience:            ${API_ID}"
echo "Dashboard client:        ${DASH_ID}"
echo "Dashboard client scope:  ${DASH_ID}-dedicated"
echo "Dashboard URL:           ${DASH_URL}"
echo "Redirect URI:            ${DASH_URL}/oauth2/callback"
echo "Post logout URI:         ${DASH_URL}/*"
```

Replace each whole template in the console steps (`openshell-api-${NS}`,
`openshell-dashboard-${NS}`, `openshell-cli-${NS}`, and `${DASH_URL}`) with
the printed value. Keep the `/oauth2/callback` and `/*` suffixes. Do not
replace only `${NS}`: the printed client IDs already include their prefixes.

### Create the realm and roles

- **Create realm** → Name: `openshell`.
- **Realm roles** → **Create role** → `openshell-admin`.
- **Realm roles** → **Create role** → `openshell-user`.

### Create users

Create two users in the `openshell` realm, for example `administrator` and
`regular-user`:

- **Users** → **Create user** → set the username and email; enable
  **Email verified** and save.
- **Credentials** → set a password.
- **Role mappings** → assign `openshell-admin` to the administrator and
  `openshell-user` to the regular user.

### Create the API audience client

The gateway acts as an OAuth 2.0 resource server: it accepts an access token
only when the token's `aud` (audience) claim names the gateway, and the
installer checks it against `oidc.audience`. Keycloak sets `aud` to the client
that requested the token, so this client provides a stable identifier,
`openshell-api-${NS}`, for the gateway API. The dashboard and CLI clients add
it to their tokens with the audience mapper described below.

- **Clients** → **Create client**
- **Client ID**: `openshell-api-${NS}`
- **Client authentication**: Off
- **Authentication flow**: disable all flows

No redirect URIs are needed because nobody signs in as this client; it exists
only to be named in tokens.

### Create the dashboard browser client

- **Clients** → **Create client**
- **Client ID**: `openshell-dashboard-${NS}`
- **Client authentication**: On
- **Authentication flow**: Standard flow
- **Root URL** and **Home URL**: `${DASH_URL}`
- **Valid redirect URIs**: `${DASH_URL}/oauth2/callback`
- **Valid post logout redirect URIs**: `${DASH_URL}/*`
- **Web origins**: `${DASH_URL}`
- **Require PKCE**: On, and **PKCE Method**: `S256` (older versions show these
  under **Advanced** as **Proof Key for Code Exchange**).
- **Client scopes** → `openshell-dashboard-${NS}-dedicated` → **Add mapper** →
  **Audience**:
  - Name: `openshell-api-audience`
  - Included Client Audience: `openshell-api-${NS}`
  - Add to access token: On
- **Credentials** → copy the client secret.

### Create the CLI client

The `openshell` CLI logs in with the Authorization Code + PKCE flow using a
public client.

- **Clients** → **Create client**
- **Client ID**: `openshell-cli-${NS}`
- **Client authentication**: Off
- **Authentication flow**: Standard flow. For headless login
  (`OPENSHELL_NO_BROWSER=1`), also enable **OAuth 2.0 Device Authorization
  Grant**. The helper leaves it off because the grant allows device-code
  phishing on a public client.
- **Valid redirect URIs**: `http://127.0.0.1/*` and optionally
  `http://localhost/*`. The CLI binds `127.0.0.1` on a random port with path
  `/callback`, so the wildcard port is required.
- **Require PKCE**: On, and **PKCE Method**: `S256`.
- **Client scopes** → `openshell-cli-${NS}-dedicated` → **Add mapper** →
  **Audience**:
  - Name: `openshell-api-audience`
  - Included Client Audience: `openshell-api-${NS}`
  - Add to access token: On

The audience mapper is required because the gateway validates
`aud == openshell-api-${NS}`, and Keycloak emits that claim only through a
mapper.

### Create the realm, roles, and clients from the command line

[`keycloak-dev-guide-create-openshell-clients.sh`](keycloak-dev-guide-create-openshell-clients.sh)
is a development helper and is not supported for production realms.

The script:

- takes its configuration from the environment variables defined at the top of
  this guide
- creates the realm, the `openshell-admin` and `openshell-user` roles, and the
  API, dashboard, and CLI clients
- writes the dashboard secret to `${CONFIG_DIR}/dashboard-client-secret.txt`
- asks for a master realm administrator's username and password and does not
  store them

Rerunning it is safe. The script creates roles only, so add the
`openshell-admin` and `openshell-user` users in the console, with verified email
addresses, and assign each role as described in [Create users](#create-users).

Export the ingress CA, then run the script from the repository root:

```shell
mkdir -p "$CONFIG_DIR"
oc -n openshift-config-managed get configmap default-ingress-cert \
  -o jsonpath='{.data.ca-bundle\.crt}' > "${CONFIG_DIR}/ingress-ca.crt"
./deploy/rhoai/keycloak-dev-guide-create-openshell-clients.sh
```

## Disconnected clusters: mirror the images

Skip this section when the cluster nodes can pull from `registry.redhat.io` and
`registry.access.redhat.com` directly. On a disconnected cluster, every image
this guide deploys must exist in a private registry the nodes can reach, and an
`ImageDigestMirrorSet` (IDMS) must rewrite the pull to that registry. IDMS
rewrites only digest references; the guide therefore deploys PostgreSQL by
digest (see [Deploy PostgreSQL with persistent
storage](#deploy-postgresql-with-persistent-storage)). Follow this section
before running Part 1.

The commands below use `registry.example.com:8443` as the private registry.
Substitute your own, and log in to both ends before copying:

```shell
export MIRROR=registry.example.com:8443
skopeo login registry.access.redhat.com
skopeo login "$MIRROR"
```

### What to mirror

Two groups of images are needed:

- The PostgreSQL image. Copy it by tag; `--all` copies the multi-arch index
  verbatim, so the digest in the mirror matches the upstream tag and the
  digest-pinned deployment in Part 1 pulls the same build:

  ```shell
  skopeo copy --all \
    docker://registry.access.redhat.com/hi/postgresql:18.4 \
    docker://$MIRROR/hi/postgresql:18.4
  ```

  Resolve the current digest of the tag when you want to pin or refresh it:
  `skopeo inspect --format '{{.Digest}}'
  docker://registry.access.redhat.com/hi/postgresql:18.4`. The `18.4` tag
  moves when Red Hat republishes the image.

- The three Red Hat build of Keycloak images the operator uses. Print them for
  the channel you plan to install:

  ```shell
  oc get packagemanifest rhbk-operator -n openshift-marketplace \
    -o jsonpath='{.status.channels[?(@.name=="stable-v26.6")].currentCSVDesc.relatedImages}'
  ```

  The output lists `registry.redhat.io/rhbk/keycloak-operator-bundle`,
  `keycloak-rhel9-operator`, and `keycloak-rhel9`, each pinned by digest. Copy
  each one, using any tag on the destination (for example the CSV version):

  ```shell
  skopeo copy --all \
    docker://registry.redhat.io/rhbk/keycloak-rhel9@sha256:<digest> \
    docker://$MIRROR/rhbk/keycloak-rhel9:v26.6.9
  ```

Push to a tag on the mirror, not to a bare digest: Quay and some other
registries accept a digest-only push but never serve the manifest afterwards,
which surfaces as `manifest unknown` when the cluster pulls. The tag does not
change the image; pulls stay pinned by digest.

### Operator catalog

The Subscription in [Install the Red Hat build of Keycloak
Operator](#install-the-red-hat-build-of-keycloak-operator) pulls the operator
manifests from a CatalogSource. Check that your cluster's catalogs contain the
package:

```shell
oc get packagemanifest rhbk-operator -n openshift-marketplace
```

If it is missing, the disconnected catalog does not include the RHBK operator;
add the package to your catalog mirror with
[oc-mirror](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/olm-restricted-networks)
and wait for the new catalog. If the CatalogSource is not named
`redhat-operators`, substitute its name in the Subscription's `source` field.

### ImageDigestMirrorSet entries

List the sources your cluster already rewrites:

```shell
oc get imagedigestmirrorset \
  -o jsonpath='{range .items[*].spec.imageDigestMirrors[*]}{.source}{"\n"}{end}' | sort -u
```

This guide needs `registry.access.redhat.com/hi` and `registry.redhat.io/rhbk`.
Add only the entries that are missing. If an oc-mirror-generated set already
covers a source, extend or reuse it instead of creating a duplicate entry; do
not create a second set for the same source. A new set with only the missing
entries looks like this:

```shell
oc apply -f - <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: hi-mirror
spec:
  imageDigestMirrors:
    - source: registry.access.redhat.com/hi
      mirrors:
        - registry.example.com:8443/hi
      mirrorSourcePolicy: NeverContactSource
EOF
```

`mirrorSourcePolicy: NeverContactSource` keeps the nodes from falling back to
the blocked public registry. Applying an IDMS change rolls out a Machine Config
Pool update, which may reboot the nodes depending on the OpenShift version;
wait for both pools to report `UPDATED=True` before deploying anything:

```shell
oc get mcp
```

## Troubleshooting

### "Client not found"

The browser redirected with a client ID that does not exist in the realm.
Confirm `openshell-dashboard-${NS}` exists and matches `oidc.client_id`. The
API client is only a token audience and does not produce this page.

### Login fails because the email is not verified

oauth2-proxy rejects ID tokens with `email_verified: false`. Enable **Email
verified** for the user in the console and save. The change applies on the next
login.

### The operator is not ready

Check the Subscription channel from Part 1, the installed CSV, and the operator
pod:

```shell
oc -n "$KEYCLOAK_NS" get subscription rhbk-operator
oc -n "$KEYCLOAK_NS" get csv
oc -n "$KEYCLOAK_NS" get pods
```

### `ImagePullBackOff` or `BundleUnpackFailed` on a disconnected cluster

The image or operator manifest is missing from the mirror, or no
`ImageDigestMirrorSet` entry rewrites its registry; a tag reference where a
digest is needed fails the same way. Check the failing pod's image and the IDMS
sources against [Disconnected clusters: mirror the
images](#disconnected-clusters-mirror-the-images).

OLM caches a failed unpack in `openshift-marketplace`. After fixing the mirror
or the IDMS, delete the failed Job and the ConfigMap of the same name so the
retry starts clean, then restart the catalog operator, which runs in
`openshift-operator-lifecycle-manager`:

```shell
oc -n openshift-marketplace get jobs
oc -n openshift-marketplace delete job <failed-unpack-job>
oc -n openshift-marketplace delete configmap <failed-unpack-job>
oc -n openshift-operator-lifecycle-manager rollout restart deployment catalog-operator
```

## Cleanup

Remove Keycloak and PostgreSQL. These commands delete only the resources this
guide creates, so they are safe when `KEYCLOAK_NS` is a shared or pre-existing
namespace:

```shell
oc delete keycloak keycloak -n "$KEYCLOAK_NS"
oc delete subscription rhbk-operator -n "$KEYCLOAK_NS"
oc delete csv -n "$KEYCLOAK_NS" -l "operators.coreos.com/rhbk-operator.${KEYCLOAK_NS}"
oc delete operatorgroup "$KEYCLOAK_NS" -n "$KEYCLOAK_NS"
oc delete all -l app=keycloak-db -n "$KEYCLOAK_NS"
oc delete pvc keycloak-db-data -n "$KEYCLOAK_NS"
oc delete secret keycloak-db-secret -n "$KEYCLOAK_NS"
```

Optionally delete the namespace as well. This is a separate step because it
deletes every workload, PersistentVolumeClaim, and resource in `KEYCLOAK_NS`,
not only the Keycloak resources. Run it only when the namespace was created
for this guide; skip it when the namespace is shared or already existed:

```shell
oc delete namespace "$KEYCLOAK_NS"
```

This guide does not delete mirrored images or `ImageDigestMirrorSet` entries;
other workloads may depend on them.
