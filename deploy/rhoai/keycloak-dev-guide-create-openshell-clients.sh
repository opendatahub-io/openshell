#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 OpenShell contributors
# SPDX-License-Identifier: Apache-2.0
#
# Create the OpenShell clients in a Keycloak realm.
#
# Development helper only. It uses the operator bootstrap admin credentials and
# disables TLS verification for Keycloak API calls. Do not use it to manage a
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
#
# Usage: keycloak-dev-guide-create-openshell-clients.sh [-y|--yes]
#   -y, --yes  Skip the confirmation prompt.
#
# The script is idempotent: rerunning skips clients and mappers that exist.

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
Existing clients and mappers are kept.

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

echo "Reading Keycloak admin credentials from ${KEYCLOAK_NS}/keycloak-initial-admin..."
AU=$(oc -n "$KEYCLOAK_NS" get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)
AP=$(oc -n "$KEYCLOAK_NS" get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)
echo "Requesting a Keycloak admin token from ${KC_URL}..."
# Keep the admin password out of the process argument list.
TOK=$(printf '%s' "$AP" | curl -fsSk -d client_id=admin-cli -d "username=$AU" \
  --data-urlencode "password@-" -d grant_type=password \
  "$KC_URL/realms/master/protocol/openid-connect/token" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
H="Authorization: Bearer $TOK"
REALM_API="$KC_URL/admin/realms/$REALM"

echo "Checking realm ${REALM}..."
status=$(curl -sSk -o /dev/null -w '%{http_code}' -H "$H" "$REALM_API")
case "$status" in
  200) echo "Keeping existing realm ${REALM}." ;;
  404)
    echo "Creating realm ${REALM}..."
    curl -fsSk -X POST -H "$H" -H "Content-Type: application/json" \
      "$KC_URL/admin/realms" -d "{\"realm\":\"$REALM\",\"enabled\":true}"
    ;;
  *)
    echo "error: cannot read realm ${REALM} (HTTP ${status})." >&2
    exit 1
    ;;
esac

for role in openshell-admin openshell-user; do
  echo "Checking realm role ${role}..."
  status=$(curl -sSk -o /dev/null -w '%{http_code}' -H "$H" "$REALM_API/roles/$role")
  case "$status" in
    200) echo "Keeping existing realm role ${role}." ;;
    404)
      echo "Creating realm role ${role}..."
      curl -fsSk -X POST -H "$H" -H "Content-Type: application/json" \
        "$REALM_API/roles" -d "{\"name\":\"$role\"}"
      ;;
    *)
      echo "error: cannot read realm role ${role} (HTTP ${status})." >&2
      exit 1
      ;;
  esac
done

API="$REALM_API/clients"
exists() { curl -fsSk -H "$H" "$API?clientId=$1" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d[0]['id'] if d else '')"; }

if [ -z "$(exists "$API_ID")" ]; then
  echo "Creating API audience client ${API_ID}..."
  curl -fsSk -X POST -H "$H" -H "Content-Type: application/json" "$API" -d "{
    \"clientId\":\"$API_ID\",\"enabled\":true,\"protocol\":\"openid-connect\",
    \"publicClient\":true,\"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false
  }"
else
  echo "Keeping existing API audience client ${API_ID}."
fi

if [ -z "$(exists "$DASH_ID")" ]; then
  echo "Creating dashboard client ${DASH_ID}..."
  curl -fsSk -X POST -H "$H" -H "Content-Type: application/json" "$API" -d "{
    \"clientId\":\"$DASH_ID\",\"enabled\":true,\"protocol\":\"openid-connect\",
    \"publicClient\":false,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,
    \"redirectUris\":[\"$DASH_URL/oauth2/callback\"],\"webOrigins\":[\"$DASH_URL\"],
    \"attributes\":{\"post.logout.redirect.uris\":\"$DASH_URL/*\",\"pkce.code.challenge.method\":\"S256\"}
  }"
else
  echo "Keeping existing dashboard client ${DASH_ID}."
fi
DASH_UUID=$(exists "$DASH_ID")
: "${DASH_UUID:?dashboard client ${DASH_ID} was not found in realm ${REALM}}"

if [ "$(curl -fsSk -H "$H" "$API/$DASH_UUID/protocol-mappers/models" \
    | python3 -c "import sys,json;print(any(m['name']=='openshell-api-audience' for m in json.load(sys.stdin)))")" != "True" ]; then
  echo "Adding audience mapper to ${DASH_ID}..."
  curl -fsSk -X POST -H "$H" -H "Content-Type: application/json" "$API/$DASH_UUID/protocol-mappers/models" -d "{
    \"name\":\"openshell-api-audience\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",
    \"config\":{\"included.client.audience\":\"$API_ID\",\"id.token.claim\":\"false\",\"access.token.claim\":\"true\"}
  }"
else
  echo "Keeping existing audience mapper on ${DASH_ID}."
fi

if [ -z "$(exists "$CLI_ID")" ]; then
  echo "Creating CLI client ${CLI_ID}..."
  curl -fsSk -X POST -H "$H" -H "Content-Type: application/json" "$API" -d "{
    \"clientId\":\"$CLI_ID\",\"enabled\":true,\"protocol\":\"openid-connect\",
    \"publicClient\":true,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,
    \"redirectUris\":[\"http://127.0.0.1/*\",\"http://localhost/*\"],
    \"attributes\":{\"pkce.code.challenge.method\":\"S256\",\"oauth2.device.authorization.grant.enabled\":\"true\"}
  }"
else
  echo "Keeping existing CLI client ${CLI_ID}."
fi
CLI_UUID=$(exists "$CLI_ID")
: "${CLI_UUID:?CLI client ${CLI_ID} was not found in realm ${REALM}}"

if [ "$(curl -fsSk -H "$H" "$API/$CLI_UUID/protocol-mappers/models" \
    | python3 -c "import sys,json;print(any(m['name']=='openshell-api-audience' for m in json.load(sys.stdin)))")" != "True" ]; then
  echo "Adding audience mapper to ${CLI_ID}..."
  curl -fsSk -X POST -H "$H" -H "Content-Type: application/json" "$API/$CLI_UUID/protocol-mappers/models" -d "{
    \"name\":\"openshell-api-audience\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",
    \"config\":{\"included.client.audience\":\"$API_ID\",\"id.token.claim\":\"false\",\"access.token.claim\":\"true\"}
  }"
else
  echo "Keeping existing audience mapper on ${CLI_ID}."
fi

echo "Writing the dashboard client secret to ${CONFIG_DIR}/dashboard-client-secret.txt (mode 0600)..."
curl -fsSk -H "$H" "$API/$DASH_UUID/client-secret" \
  | python3 -c "import sys,json;sys.stdout.write(json.load(sys.stdin)['value'])" \
  > "${CONFIG_DIR}/dashboard-client-secret.txt"
chmod 600 "${CONFIG_DIR}/dashboard-client-secret.txt"
echo "Clients ready; dashboard client secret written to ${CONFIG_DIR}/dashboard-client-secret.txt"
