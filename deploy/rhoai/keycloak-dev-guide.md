# Install Keycloak for OpenShell development on OpenShift

This guide is for development only. It is not a production Keycloak
deployment: it runs one PostgreSQL instance and one Keycloak instance with
bootstrap credentials, and the client helper verifies the Keycloak Route
against the cluster ingress CA.

This guide deploys and removes a development Keycloak instance only. Use
[README.md](README.md) to install OpenShell and the OpenShell Dashboard admin UI.
Follow this guide first when you need a local identity provider; skip it when
your cluster already has an OIDC provider.

Set the environment used throughout the guide:

```shell
export APPS_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
export NS=openshell-team
export KEYCLOAK_NS=keycloak
export REALM=openshell
export API_ID="openshell-api-${NS}"
export DASH_ID="openshell-dashboard-${NS}"
export CLI_ID=openshell-cli
export DASH_URL="https://dashboard-${NS}.${APPS_DOMAIN}"
export KC_URL="https://keycloak.${APPS_DOMAIN}"
export CONFIG_DIR="${HOME}/.config/openshell-rhoai"
```

The client IDs are namespace-qualified and match the example configurations, so
the commands work unchanged for the default namespace. `DASH_URL` also matches
the host the installer derives from the namespace and ingress domain, so the
example configurations need no host changes. Changing `NS` changes the client
IDs, `DASH_URL`, and both derived hosts; update the OIDC identifiers in the
OpenShell configuration from [README.md](README.md) and re-register
`https://<new-dashboard-host>/oauth2/callback` with Keycloak. If the
configuration sets explicit hosts, register that dashboard URL instead.

## Part 1 — PostgreSQL and Keycloak

### Create the namespace and database secret

```shell
oc new-project "$KEYCLOAK_NS"
oc -n "$KEYCLOAK_NS" create secret generic keycloak-db-secret \
  --from-literal=username=keycloak \
  --from-literal=password="$(openssl rand -base64 24)"
```

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

Deploy PostgreSQL from the Red Hat hardened image. `PGDATA` points to a
subdirectory to avoid the `lost+found` conflict at the mount point:

```shell
oc -n "$KEYCLOAK_NS" new-app registry.access.redhat.com/hi/postgresql:18.4 \
  -e POSTGRES_USER=keycloak \
  -e POSTGRES_DATABASE=keycloak \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  --name=keycloak-db
```

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

## Part 2 — Realm configuration

Perform these steps in the Keycloak admin console unless a section says
otherwise. The command-line script in this part creates the realm, roles, and
clients; create the users in the console. When a Keycloak administrator already
created the registrations, use their values instead and skip the sections you
do not need.

### Create the realm and roles

- **Create realm** → Name: `openshell`.
- **Realm roles** → **Create role** → `openshell-admin`.
- **Realm roles** → **Create role** → `openshell-user`.

### Create users

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
- **Client ID**: `openshell-cli`
- **Client authentication**: Off
- **Authentication flow**: Standard flow; optionally enable
  **OAuth 2.0 Device Authorization Grant** for headless login
  (`OPENSHELL_NO_BROWSER=1`).
- **Valid redirect URIs**: `http://127.0.0.1/*` and optionally
  `http://localhost/*`. The CLI binds `127.0.0.1` on a random port with path
  `/callback`, so the wildcard port is required.
- **Require PKCE**: On, and **PKCE Method**: `S256`.
- **Client scopes** → `openshell-cli-dedicated` → **Add mapper** → **Audience**:
  - Name: `openshell-api-audience`
  - Included Client Audience: `openshell-api-${NS}`
  - Add to access token: On

The audience mapper is required because the gateway validates
`aud == openshell-api-${NS}`, and Keycloak emits that claim only through a
mapper.

### Create the realm, roles, and clients from the command line

[`keycloak-dev-guide-create-openshell-clients.sh`](keycloak-dev-guide-create-openshell-clients.sh)
creates the realm when missing, the `openshell-admin` and `openshell-user`
realm roles, and the API, dashboard, and CLI clients through the admin REST
API. It writes the dashboard secret to
`${CONFIG_DIR}/dashboard-client-secret.txt`, so you can skip the console steps
for the realm, roles, and clients. Create the users in the console; they need
passwords and verified email addresses. The script is idempotent: rerunning
keeps existing objects and reconciles the dashboard client redirect settings
with `DASH_URL`. The script prints the target and asks for confirmation before
changing anything; pass `--yes` to skip the prompt. It requires `oc`, `curl`,
and `python3`, and reads the environment variables set at the top of this guide.
It verifies the Keycloak Route against a bundle built from the system roots and
`${CONFIG_DIR}/ingress-ca.crt`, and exits if that file is missing.

Export the ingress CA, then run the script from the repository root after the
Keycloak instance is ready:

```shell
oc -n openshift-config-managed get configmap default-ingress-cert \
  -o jsonpath='{.data.ca-bundle\.crt}' > "${CONFIG_DIR}/ingress-ca.crt"
./deploy/rhoai/keycloak-dev-guide-create-openshell-clients.sh
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

## Cleanup

Remove Keycloak and PostgreSQL. These commands delete only the resources this
guide creates, so they are safe when `KEYCLOAK_NS` is a shared or pre-existing
namespace:

```shell
oc delete keycloak keycloak -n "$KEYCLOAK_NS"
oc delete subscription rhbk-operator -n "$KEYCLOAK_NS"
oc delete csv -n "$KEYCLOAK_NS" -l operators.coreos.com/rhbk-operator.keycloak
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
