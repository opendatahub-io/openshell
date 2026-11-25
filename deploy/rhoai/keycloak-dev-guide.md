# Install Keycloak for OpenShell development on OpenShift

This guide sets up Keycloak for development on OpenShift. It is not for
production: it runs one PostgreSQL instance and one Keycloak instance, uses
temporary bootstrap credentials, and the client setup helper checks the
Keycloak Route against the cluster's ingress CA.

Use [README.md](README.md) to install OpenShell and the OpenShell Dashboard
admin UI. Follow this guide if you need a local identity provider. Skip it if
your cluster already has an OIDC provider. If your cluster cannot reach public
registries, first follow the [disconnected-cluster instructions](#disconnected-clusters-mirror-the-images).

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

These namespace-qualified client IDs match the examples, so the commands work
with the default namespace. `DASH_URL` also matches the host the installer
builds from the namespace and ingress domain.

If you change `NS`, update the OIDC identifiers in the OpenShell configuration
from [README.md](README.md), then register the new dashboard callback URL
(`https://<new-dashboard-host>/oauth2/callback`) in Keycloak. If your
configuration sets a dashboard host directly, register that URL instead.

Realm roles apply to the whole realm. Anyone with `openshell-admin` can
administer every gateway in that realm, whatever the client IDs are. Use a
separate realm for each group of gateways that should have its own access
boundary.

## Part 1: PostgreSQL and Keycloak

### Create the namespace and database secret

```shell
oc new-project "$KEYCLOAK_NS"
openssl rand -base64 24 | tr -d '\n' | \
  oc -n "$KEYCLOAK_NS" create secret generic keycloak-db-secret \
    --from-literal=username=keycloak --from-file=password=/dev/stdin
```

Passing the generated password through stdin keeps it out of the process list.

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

Deploy PostgreSQL from Red Hat's hardened image and pin it by digest. The image
is public. To use a newer build, get the current digest for the `18.4` tag:

```shell
skopeo inspect --format '{{.Digest}}' \
  docker://registry.access.redhat.com/hi/postgresql:18.4
oc -n "$KEYCLOAK_NS" new-app registry.access.redhat.com/hi/postgresql@sha256:67599d73c3dae0e8685c2f9ba31c11028477816bbc254cf862543cfb11c2dc3f \
  -e POSTGRES_USER=keycloak \
  -e POSTGRES_DATABASE=keycloak \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  --name=keycloak-db
```

Use the digest form on disconnected clusters. An `ImageDigestMirrorSet` can
redirect digest pulls to your mirror, but tag pulls still go to the original
registry and fail.

Keep the database password out of the `oc new-app` command. Otherwise it can
appear in the process list and as plain text in the Deployment. Add a reference
to `keycloak-db-secret` instead:

```shell
oc -n "$KEYCLOAK_NS" patch deployment/keycloak-db --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"POSTGRES_PASSWORD","valueFrom":{"secretKeyRef":{"name":"keycloak-db-secret","key":"password"}}}}]'
```

Use the claim instead of the image's temporary `emptyDir` volume. The image
usually names its volume `keycloak-db-volume-1` and mounts it at
`/var/lib/postgresql`. Check the Deployment if your image uses a different
volume name:

```shell
oc -n "$KEYCLOAK_NS" set volume deployment/keycloak-db \
  --add --overwrite --name=keycloak-db-volume-1 \
  --type=persistentVolumeClaim \
  --claim-name=keycloak-db-data \
  --mount-path=/var/lib/postgresql
oc -n "$KEYCLOAK_NS" rollout status deployment/keycloak-db
```

### Install the Red Hat build of Keycloak Operator

Install the operator from the OpenShift console or with a Subscription. In the
console, go to **Operators** → **OperatorHub**, search for **Red Hat build of
Keycloak**, and install it in the `keycloak` namespace or in all namespaces.
Then wait for the operator to start:

```shell
oc -n "$KEYCLOAK_NS" rollout status deployment/rhbk-operator
```

If you installed it for all namespaces, the Deployment is in
`openshift-operators`. Use `-n openshift-operators` in the command above.

To install with a Subscription, first list the available channels and choose
one from the output:

```shell
oc get packagemanifest rhbk-operator -n openshift-marketplace \
  -o jsonpath='{.status.channels[*].name}'
```

The example uses `stable-v26.6` and the `KEYCLOAK_NS` value you set earlier.
Channel names can change between releases, so replace the example channel if
your cluster lists a different one.

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

Check whether the namespace already has an OperatorGroup:

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

The Subscription installs in the background. Wait for the operator to be ready
before creating the Keycloak instance; otherwise, the Keycloak custom resource
may not be available yet:

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

The `hostname` setting tells the operator to create and manage an
edge-terminated Route for this host. Do not create a Route yourself, or it will
conflict with the operator's Route.

### Get the admin credentials

```shell
oc -n "$KEYCLOAK_NS" get route
echo "console:  ${KC_URL}/admin/"
echo "username: $(oc -n "$KEYCLOAK_NS" get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)"
echo "password: $(oc -n "$KEYCLOAK_NS" get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)"
```

The bootstrap administrator is named `temp-admin`. Sign in to the master realm
with these credentials, then create a permanent administrator. The bootstrap
account is temporary.

Once the permanent administrator can sign in, delete the bootstrap user:
**Users** → `temp-admin` → **Delete**. This prevents the shared development
credentials from staying valid for the life of the realm.

## Part 2: Realm configuration

Unless noted otherwise, do these steps in the Keycloak admin console. The helper
script later in this part can create the realm, roles, and clients, but you must
create users in the console. If an administrator already created some of these
items, use their values and skip those steps.

The Keycloak console cannot expand shell variables. Print the values, then copy
them into the console:

```shell
echo "API audience:            ${API_ID}"
echo "Dashboard client:        ${DASH_ID}"
echo "Dashboard client scope:  ${DASH_ID}-dedicated"
echo "Dashboard URL:           ${DASH_URL}"
echo "Redirect URI:            ${DASH_URL}/oauth2/callback"
echo "Post logout URI:         ${DASH_URL}/*"
```

In the console steps, replace each full template (`openshell-api-${NS}`,
`openshell-dashboard-${NS}`, `openshell-cli-${NS}`, and `${DASH_URL}`) with its
printed value. Keep the `/oauth2/callback` and `/*` endings. The printed client
IDs already include their prefixes, so replace the whole template rather than
just `${NS}`.

### Create the realm and roles

- **Create realm** → Name: `openshell`.
- **Realm roles** → **Create role** → `openshell-admin`.
- **Realm roles** → **Create role** → `openshell-user`.

### Create users

Create two users in the `openshell` realm, such as `administrator` and
`regular-user`:

- **Users** → **Create user** → set the username and email; enable
  **Email verified** and save.
- **Credentials** → set a password.
- **Role mappings** → assign `openshell-admin` to the administrator and
  `openshell-user` to the regular user.

### Create the API audience client

The gateway accepts an access token only if its `aud` (audience) claim names
the gateway. The installer checks this value against `oidc.audience`. Keycloak
normally sets `aud` to the client that requested the token, so create this
client to give the gateway a stable audience ID: `openshell-api-${NS}`. The
dashboard and CLI clients add this ID to their tokens with the audience mapper
below.

- **Clients** → **Create client**
- **Client ID**: `openshell-api-${NS}`
- **Client authentication**: Off
- **Authentication flow**: disable all flows

No redirect URIs are needed. Users do not sign in with this client; tokens only
refer to its ID.

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

The `openshell` CLI uses a public client and the Authorization Code + PKCE
login flow.

- **Clients** → **Create client**
- **Client ID**: `openshell-cli-${NS}`
- **Client authentication**: Off
- **Authentication flow**: Standard flow. For headless login
  (`OPENSHELL_NO_BROWSER=1`), also enable **OAuth 2.0 Device Authorization
  Grant**. The helper leaves this off because device codes on a public client
  can be used for phishing.
- **Valid redirect URIs**: `http://127.0.0.1/*` and optionally
  `http://localhost/*`. The CLI listens on `127.0.0.1` at a random port and
  uses the `/callback` path, so the port must be a wildcard.
- **Require PKCE**: On, and **PKCE Method**: `S256`.
- **Client scopes** → `openshell-cli-${NS}-dedicated` → **Add mapper** →
  **Audience**:
  - Name: `openshell-api-audience`
  - Included Client Audience: `openshell-api-${NS}`
  - Add to access token: On

The mapper is required. The gateway checks for
`aud == openshell-api-${NS}`, and Keycloak adds that audience only through a
mapper.

### Create the realm, roles, and clients with a helper script

Use the [helper script](keycloak-dev-guide-create-openshell-clients.sh) for
development only. It is not supported for production realms.

The script:

- takes its configuration from the environment variables defined at the top of
  this guide
- creates the realm, the `openshell-admin` and `openshell-user` roles, and the
  API, dashboard, and CLI clients
- writes the dashboard secret to `${CONFIG_DIR}/dashboard-client-secret.txt`
- asks for a master realm administrator's username and password and does not
  store them

You can run the script again safely. It creates the realm, roles, and clients,
but not users. Create users in the console, verify their email addresses, and
assign the `openshell-admin` or `openshell-user` role as described in
[Create users](#create-users).

Export the ingress CA, then run the script from the repository root:

```shell
mkdir -p "$CONFIG_DIR"
oc -n openshift-config-managed get configmap default-ingress-cert \
  -o jsonpath='{.data.ca-bundle\.crt}' > "${CONFIG_DIR}/ingress-ca.crt"
./deploy/rhoai/keycloak-dev-guide-create-openshell-clients.sh
```

## Disconnected clusters: mirror the images

Skip this section if your cluster nodes can pull directly from
`registry.redhat.io` and `registry.access.redhat.com`. Otherwise, copy every
image used by this guide to a private registry the nodes can reach, and
configure an `ImageDigestMirrorSet` (IDMS) to redirect pulls there. IDMS
redirects digest references only, so this guide pins PostgreSQL by digest (see
[PostgreSQL deployment section](#deploy-postgresql-with-persistent-storage)). Complete this section
before Part 1.

The examples use `registry.example.com:8443` as the private registry. Replace
it with your registry, then log in to both registries before copying images:

```shell
export MIRROR=registry.example.com:8443
skopeo login registry.access.redhat.com
skopeo login "$MIRROR"
```

### What to mirror

You need two groups of images:

- The PostgreSQL image. Copy it by tag. `--all` preserves its multi-architecture
  index, so the mirror has the same digest and Part 1 pulls the same build:

  ```shell
  skopeo copy --all \
    docker://registry.access.redhat.com/hi/postgresql:18.4 \
    docker://$MIRROR/hi/postgresql:18.4
  ```

  To pin or update the image, check the tag's current digest:
  `skopeo inspect --format '{{.Digest}}'
  docker://registry.access.redhat.com/hi/postgresql:18.4`. Red Hat may update
  the image behind the `18.4` tag.

- The three Red Hat build of Keycloak images used by the operator. Print the
  image list for the channel you plan to install:

  ```shell
  oc get packagemanifest rhbk-operator -n openshift-marketplace \
    -o jsonpath='{.status.channels[?(@.name=="stable-v26.6")].currentCSVDesc.relatedImages}'
  ```

  The output lists `registry.redhat.io/rhbk/keycloak-operator-bundle`,
  `keycloak-rhel9-operator`, and `keycloak-rhel9`, each with a digest. Copy each
  image and give it any tag in the mirror, such as the CSV version:

  ```shell
  skopeo copy --all \
    docker://registry.redhat.io/rhbk/keycloak-rhel9@sha256:<digest> \
    docker://$MIRROR/rhbk/keycloak-rhel9:v26.6.9
  ```

Push each image to a tag in the mirror, not to a bare digest. Quay and some
other registries may accept a digest-only push but fail to serve it later,
causing `manifest unknown` errors. The tag does not change the image; the
cluster still pulls it by digest.

### Operator catalog

The Subscription in the [operator installation section](#install-the-red-hat-build-of-keycloak-operator)
gets operator manifests from a CatalogSource. Check that the package is in your cluster's
catalogs:

```shell
oc get packagemanifest rhbk-operator -n openshift-marketplace
```

If it is missing, your catalog mirror does not include the RHBK operator. Add
the package with
[oc-mirror](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/olm-restricted-networks)
and wait for the updated catalog. If your CatalogSource has a different name,
use that name in the Subscription's `source` field.

### ImageDigestMirrorSet entries

List the image sources your cluster already redirects:

```shell
oc get imagedigestmirrorset \
  -o jsonpath='{range .items[*].spec.imageDigestMirrors[*]}{.source}{"\n"}{end}' | sort -u
```

This guide needs `registry.access.redhat.com/hi` and `registry.redhat.io/rhbk`.
Add only sources that are missing. If an oc-mirror set already covers a source,
reuse or extend it. Do not create a second set for the same source. To create a
set with only the missing entries:

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

`mirrorSourcePolicy: NeverContactSource` prevents nodes from falling back to
the public registry. Changing an IDMS starts a Machine Config Pool update and
may reboot nodes, depending on your OpenShift version. Wait until both pools
show `UPDATED=True` before deploying:

```shell
oc get mcp
```

## Troubleshooting

### "Client not found"

The browser was redirected with a client ID that Keycloak cannot find. Check
that `openshell-dashboard-${NS}` exists and matches `oidc.client_id`. The API
client is only used as a token audience, so it does not cause this error.

### Login fails because the email is not verified

oauth2-proxy rejects ID tokens when `email_verified` is `false`. In the console,
enable **Email verified** for the user and save. It takes effect at the next
login.

### The operator is not ready

Check the Subscription channel from Part 1, the installed CSV, and the operator
pod status:

```shell
oc -n "$KEYCLOAK_NS" get subscription rhbk-operator
oc -n "$KEYCLOAK_NS" get csv
oc -n "$KEYCLOAK_NS" get pods
```

### `ImagePullBackOff` or `BundleUnpackFailed` on a disconnected cluster

The mirror may be missing the image or operator manifest, or the
`ImageDigestMirrorSet` may not redirect its registry. Using a tag where a digest
is required causes the same error. Compare the failing pod's image and the IDMS
sources with the [disconnected-cluster instructions](#disconnected-clusters-mirror-the-images).

OLM keeps failed unpack results in `openshift-marketplace`. After fixing the
mirror or IDMS, delete the failed Job and the ConfigMap with the same name.
Then restart the catalog operator in
`openshift-operator-lifecycle-manager`:

```shell
oc -n openshift-marketplace get jobs
oc -n openshift-marketplace delete job <failed-unpack-job>
oc -n openshift-marketplace delete configmap <failed-unpack-job>
oc -n openshift-operator-lifecycle-manager rollout restart deployment catalog-operator
```

## Cleanup

Remove Keycloak and PostgreSQL with these commands. They delete only the
resources created by this guide, so you can use them in a shared or existing
`KEYCLOAK_NS` namespace:

```shell
oc delete keycloak keycloak -n "$KEYCLOAK_NS"
oc delete subscription rhbk-operator -n "$KEYCLOAK_NS"
oc delete csv -n "$KEYCLOAK_NS" -l "operators.coreos.com/rhbk-operator.${KEYCLOAK_NS}"
oc delete operatorgroup "$KEYCLOAK_NS" -n "$KEYCLOAK_NS"
oc delete all -l app=keycloak-db -n "$KEYCLOAK_NS"
oc delete pvc keycloak-db-data -n "$KEYCLOAK_NS"
oc delete secret keycloak-db-secret -n "$KEYCLOAK_NS"
```

You can also delete the namespace, but that removes everything in
`KEYCLOAK_NS`, including workloads and persistent volume claims. Do this only
if you created the namespace for this guide. Skip it for a shared or existing
namespace:

```shell
oc delete namespace "$KEYCLOAK_NS"
```

These commands leave mirrored images and `ImageDigestMirrorSet` entries in
place because other workloads may use them.
