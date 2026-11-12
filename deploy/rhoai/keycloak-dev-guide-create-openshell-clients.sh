#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 OpenShell contributors
# SPDX-License-Identifier: Apache-2.0
#
# Create the OpenShell clients in a Keycloak realm.
#
# Development helper only. It uses the operator bootstrap admin credentials and
# verifies the Keycloak Route against a bundle built from the system roots and
# the ingress CA at "${CONFIG_DIR}/ingress-ca.crt". Do not use it to manage a
# production realm.
#
# The script creates the realm and the openshell-admin/openshell-user realm
# roles when missing. It also creates the API audience client, the dashboard
# browser client, and the CLI client, then writes the dashboard client secret
# to "${CONFIG_DIR}/dashboard-client-secret.txt" with mode 0600. Create the
# users separately; they need passwords and verified email addresses.
#
# Requires the environment variables set by the Keycloak development guide:
#   KC_URL, KEYCLOAK_NS, REALM, API_ID, DASH_ID, CLI_ID, DASH_URL, CONFIG_DIR
# CONFIG_DIR must contain ingress-ca.crt, the CA bundle for the Keycloak Route.
#
# Usage: keycloak-dev-guide-create-openshell-clients.sh [-y|--yes]
#   -y, --yes  Skip the confirmation prompt.
#
# The script is idempotent: rerunning keeps existing objects and reconciles the
# dashboard client redirect settings with DASH_URL.

set -euo pipefail
umask 077

: "${KC_URL:?set KC_URL, for example https://keycloak.apps.example.com}"
: "${KEYCLOAK_NS:?set KEYCLOAK_NS, for example keycloak}"
: "${REALM:?set REALM, for example openshell}"
: "${API_ID:?set API_ID, for example openshell-api-openshell-team}"
: "${DASH_ID:?set DASH_ID, for example openshell-dashboard-openshell-team}"
: "${CLI_ID:?set CLI_ID, for example openshell-cli}"
: "${DASH_URL:?set DASH_URL, for example https://dashboard-openshell-team.apps.example.com}"
: "${CONFIG_DIR:?set CONFIG_DIR, for example ${HOME}/.config/openshell-rhoai}"

assume_yes=false
case "${1:-}" in
  -y | --yes) assume_yes=true ;;
  "") ;;
  *)
    echo "usage: $0 [-y|--yes]" >&2
    exit 2
    ;;
esac

cat <<EOF
This configures OpenShell clients in Keycloak:
  Keycloak:      ${KC_URL}
  Realm:         ${REALM} (created if missing)
  Realm roles:   openshell-admin, openshell-user (created if missing)
  Admin secret:  ${KEYCLOAK_NS}/keycloak-initial-admin
  API audience:  ${API_ID} (public, no login flow)
  Dashboard:     ${DASH_ID} (confidential, callback ${DASH_URL}/oauth2/callback)
  CLI:           ${CLI_ID} (public, PKCE)
  Secret output: ${CONFIG_DIR}/dashboard-client-secret.txt (mode 0600)
Existing clients are kept; the dashboard redirect settings are reconciled.

EOF

if [ "$assume_yes" != true ]; then
  if [ ! -t 0 ]; then
    echo "error: no interactive terminal; rerun with --yes to confirm." >&2
    exit 1
  fi
  printf 'Continue? [y/N] ' >&2
  read -r reply
  case "$reply" in
    y | Y | yes | YES) ;;
    *)
      echo "Aborted." >&2
      exit 1
      ;;
  esac
fi

echo "Preparing ${CONFIG_DIR} (mode 0700)..."
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

CACERT="${CONFIG_DIR}/ingress-ca.crt"
[ -s "$CACERT" ] || {
  echo "error: missing ${CACERT}; export the ingress CA as described in the guide." >&2
  exit 1
}
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# Combine the system roots with the ingress CA so curl trusts both public and
# cluster-internal issuers. --cacert replaces the default bundle.
CURL_CA="${WORK_DIR}/ca-bundle.pem"
for bundle in \
  /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
  /etc/ssl/certs/ca-certificates.crt \
  /etc/ssl/cert.pem; do
  if [ -f "$bundle" ]; then
    cat "$bundle" >> "$CURL_CA"
    break
  fi
done
cat "$CACERT" >> "$CURL_CA"

echo "Reading Keycloak admin credentials from ${KEYCLOAK_NS}/keycloak-initial-admin..."
AU=$(oc -n "$KEYCLOAK_NS" get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)
AP=$(oc -n "$KEYCLOAK_NS" get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)
echo "Requesting a Keycloak admin token from ${KC_URL}..."
# Keep the admin password out of the process argument list.
TOK=$(printf '%s' "$AP" | curl -fsS --cacert "$CURL_CA" -d client_id=admin-cli -d "username=$AU" \
  --data-urlencode "password@-" -d grant_type=password \
  "$KC_URL/realms/master/protocol/openid-connect/token" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
# Keep the admin token out of the process argument list. WORK_DIR is created by
# mktemp and the script sets umask 077, so the file is private.
HDR_FILE="${WORK_DIR}/auth.hdr"
printf 'header = "Authorization: Bearer %s"\n' "$TOK" > "$HDR_FILE"
chmod 600 "$HDR_FILE"
REALM_API="$KC_URL/admin/realms/$REALM"

echo "Checking realm ${REALM}..."
status=$(curl -sS --cacert "$CURL_CA" -o /dev/null -w '%{http_code}' -K "$HDR_FILE" "$REALM_API")
case "$status" in
  200) echo "Keeping existing realm ${REALM}." ;;
  404)
    echo "Creating realm ${REALM}..."
    curl -fsS --cacert "$CURL_CA" -X POST -K "$HDR_FILE" -H "Content-Type: application/json" \
      "$KC_URL/admin/realms" -d "{\"realm\":\"$REALM\",\"enabled\":true}"
    ;;
  *)
    echo "error: cannot read realm ${REALM} (HTTP ${status})." >&2
    exit 1
    ;;
esac

for role in openshell-admin openshell-user; do
  echo "Checking realm role ${role}..."
  status=$(curl -sS --cacert "$CURL_CA" -o /dev/null -w '%{http_code}' -K "$HDR_FILE" "$REALM_API/roles/$role")
  case "$status" in
    200) echo "Keeping existing realm role ${role}." ;;
    404)
      echo "Creating realm role ${role}..."
      curl -fsS --cacert "$CURL_CA" -X POST -K "$HDR_FILE" -H "Content-Type: application/json" \
        "$REALM_API/roles" -d "{\"name\":\"$role\"}"
      ;;
    *)
      echo "error: cannot read realm role ${role} (HTTP ${status})." >&2
      exit 1
      ;;
  esac
done

API="$REALM_API/clients"
exists() {
  curl -fsS --cacert "$CURL_CA" -G -K "$HDR_FILE" \
    --data-urlencode "clientId=$1" "$API" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(d[0]['id'] if d else '')"
}
has_audience() {
  python3 -c "import sys,json;print(any(m.get('config',{}).get('included.client.audience')==sys.argv[1] for m in json.load(sys.stdin)))" "$1"
}
ensure_audience_mapper() {
  # $1 is the client UUID, $2 the client ID used in messages.
  local uuid="$1" client="$2"
  if [ "$(curl -fsS --cacert "$CURL_CA" -K "$HDR_FILE" "$API/$uuid/protocol-mappers/models" \
      | has_audience "$API_ID")" != "True" ]; then
    echo "Adding audience mapper to ${client}..."
    curl -fsS --cacert "$CURL_CA" -X POST -K "$HDR_FILE" -H "Content-Type: application/json" "$API/$uuid/protocol-mappers/models" -d "{
      \"name\":\"openshell-api-audience-$API_ID\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",
      \"config\":{\"included.client.audience\":\"$API_ID\",\"id.token.claim\":\"false\",\"access.token.claim\":\"true\"}
    }"
  else
    echo "Keeping existing audience mapper on ${client}."
  fi
}

if [ -z "$(exists "$API_ID")" ]; then
  echo "Creating API audience client ${API_ID}..."
  curl -fsS --cacert "$CURL_CA" -X POST -K "$HDR_FILE" -H "Content-Type: application/json" "$API" -d "{
    \"clientId\":\"$API_ID\",\"enabled\":true,\"protocol\":\"openid-connect\",
    \"publicClient\":true,\"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false
  }"
else
  echo "Keeping existing API audience client ${API_ID}."
fi

DASH_UUID=$(exists "$DASH_ID")
if [ -z "$DASH_UUID" ]; then
  echo "Creating dashboard client ${DASH_ID}..."
  curl -fsS --cacert "$CURL_CA" -X POST -K "$HDR_FILE" -H "Content-Type: application/json" "$API" -d "{
    \"clientId\":\"$DASH_ID\",\"enabled\":true,\"protocol\":\"openid-connect\",
    \"publicClient\":false,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,
    \"redirectUris\":[\"$DASH_URL/oauth2/callback\"],\"webOrigins\":[\"$DASH_URL\"],
    \"attributes\":{\"post.logout.redirect.uris\":\"$DASH_URL/*\",\"pkce.code.challenge.method\":\"S256\"}
  }"
  DASH_UUID=$(exists "$DASH_ID")
  : "${DASH_UUID:?dashboard client ${DASH_ID} was not found in realm ${REALM}}"
else
  echo "Checking dashboard client ${DASH_ID} redirect settings..."
  DASH_CLIENT="${WORK_DIR}/dashboard-client.json"
  curl -fsS --cacert "$CURL_CA" -K "$HDR_FILE" "$API/$DASH_UUID" > "$DASH_CLIENT"
  if python3 - "$DASH_URL" "$DASH_CLIENT" <<'PY'
import json
import sys

url, path = sys.argv[1], sys.argv[2]
with open(path) as source:
    client = json.load(source)
attributes = client.setdefault("attributes", {})
redirect = url + "/oauth2/callback"
logout = url + "/*"
changed = False
if client.get("redirectUris") != [redirect]:
    client["redirectUris"] = [redirect]
    changed = True
if client.get("webOrigins") != [url]:
    client["webOrigins"] = [url]
    changed = True
if attributes.get("post.logout.redirect.uris") != logout:
    attributes["post.logout.redirect.uris"] = logout
    changed = True
if changed:
    with open(path, "w") as target:
        json.dump(client, target)
sys.exit(0 if changed else 1)
PY
  then
    echo "Updating dashboard client ${DASH_ID} for ${DASH_URL}..."
    curl -fsS --cacert "$CURL_CA" -X PUT -K "$HDR_FILE" -H "Content-Type: application/json" \
      --data-binary "@$DASH_CLIENT" "$API/$DASH_UUID"
  else
    echo "Keeping existing dashboard client ${DASH_ID}."
  fi
fi

ensure_audience_mapper "$DASH_UUID" "$DASH_ID"

if [ -z "$(exists "$CLI_ID")" ]; then
  echo "Creating CLI client ${CLI_ID}..."
  curl -fsS --cacert "$CURL_CA" -X POST -K "$HDR_FILE" -H "Content-Type: application/json" "$API" -d "{
    \"clientId\":\"$CLI_ID\",\"enabled\":true,\"protocol\":\"openid-connect\",
    \"publicClient\":true,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,
    \"redirectUris\":[\"http://127.0.0.1/*\",\"http://localhost/*\"],
    \"attributes\":{\"pkce.code.challenge.method\":\"S256\"}
  }"
else
  echo "Keeping existing CLI client ${CLI_ID}."
fi
CLI_UUID=$(exists "$CLI_ID")
: "${CLI_UUID:?CLI client ${CLI_ID} was not found in realm ${REALM}}"

ensure_audience_mapper "$CLI_UUID" "$CLI_ID"

SECRET_FILE="${CONFIG_DIR}/dashboard-client-secret.txt"
SECRET_TMP="${WORK_DIR}/dashboard-client-secret.txt"
echo "Writing the dashboard client secret to ${SECRET_FILE} (mode 0600)..."
curl -fsS --cacert "$CURL_CA" -K "$HDR_FILE" "$API/$DASH_UUID/client-secret" \
  | python3 -c "import sys,json;sys.stdout.write(json.load(sys.stdin)['value'])" \
  > "$SECRET_TMP"
[ -s "$SECRET_TMP" ] || {
  echo "error: Keycloak returned an empty dashboard client secret." >&2
  exit 1
}
chmod 600 "$SECRET_TMP"
mv -f "$SECRET_TMP" "$SECRET_FILE"
echo "Clients ready; dashboard client secret written to ${SECRET_FILE}"
