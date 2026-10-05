#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Update token lifetimes for the isolated OpenShell Keycloak realm."""

from __future__ import annotations

import argparse
import base64
import json
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


def bootstrap_admin_credentials(namespace: str, keycloak_name: str) -> tuple[str, str]:
    secret_name = f"{keycloak_name}-initial-admin"
    result = subprocess.run(
        ["oc", "-n", namespace, "get", "secret", secret_name, "-o", "json"],
        capture_output=True,
        check=True,
        text=True,
    )
    secret = json.loads(result.stdout)
    data = secret["data"]
    username = base64.b64decode(data["username"]).decode("utf-8")
    password = base64.b64decode(data["password"]).decode("utf-8")
    return username, password


def realm_admin_urls(issuer: str) -> tuple[str, str]:
    issuer = issuer.rstrip("/")
    marker = "/realms/"
    if marker not in issuer:
        raise ValueError("issuer URL must include a realm path")
    base_url, realm = issuer.rsplit(marker, 1)
    if not realm or "/" in realm:
        raise ValueError("issuer URL must identify exactly one realm")
    token_url = f"{base_url}{marker}master/protocol/openid-connect/token"
    realm_url = f"{base_url}/admin/realms/{urllib.parse.quote(realm, safe='')}"
    return token_url, realm_url


def request_json(
    url: str,
    *,
    context: ssl.SSLContext,
    method: str = "GET",
    payload: bytes | None = None,
    content_type: str = "application/json",
    access_token: str | None = None,
) -> dict[str, object] | None:
    headers = {"Accept": "application/json"}
    if payload is not None:
        headers["Content-Type"] = content_type
    if access_token is not None:
        headers["Authorization"] = f"Bearer {access_token}"
    request = urllib.request.Request(url, data=payload, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, context=context, timeout=30) as response:
            if response.status == 204:
                return None
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Keycloak Admin API returned HTTP {error.code}") from None
    except urllib.error.URLError as error:
        raise RuntimeError(
            f"Keycloak Admin API request failed: {error.reason}"
        ) from None


def update_realm_lifetimes(
    *,
    issuer: str,
    ca_file: str | None,
    namespace: str,
    keycloak_name: str,
    access_token_lifespan: int,
    client_session_max_lifespan: int,
) -> None:
    if (
        access_token_lifespan <= 0
        or client_session_max_lifespan <= access_token_lifespan
    ):
        raise ValueError(
            "client session lifespan must be greater than positive access-token lifespan"
        )

    username, password = bootstrap_admin_credentials(namespace, keycloak_name)
    token_url, realm_url = realm_admin_urls(issuer)
    context = ssl.create_default_context(cafile=ca_file)
    token_payload = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": username,
            "password": password,
        }
    ).encode("utf-8")
    token_response = request_json(
        token_url,
        context=context,
        method="POST",
        payload=token_payload,
        content_type="application/x-www-form-urlencoded",
    )
    if not token_response or not isinstance(token_response.get("access_token"), str):
        raise RuntimeError("Keycloak did not return an admin access token")
    access_token = token_response["access_token"]

    lifetimes = {
        "accessTokenLifespan": access_token_lifespan,
        "clientSessionMaxLifespan": client_session_max_lifespan,
    }
    request_json(
        realm_url,
        context=context,
        method="PUT",
        payload=json.dumps(lifetimes).encode("utf-8"),
        access_token=access_token,
    )
    current_realm = request_json(realm_url, context=context, access_token=access_token)
    if not current_realm or any(
        current_realm.get(key) != value for key, value in lifetimes.items()
    ):
        raise RuntimeError("Keycloak realm lifetime update did not persist")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--ca-file")
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--keycloak-name", required=True)
    parser.add_argument("--access-token-lifespan", required=True, type=int)
    parser.add_argument("--client-session-max-lifespan", required=True, type=int)
    args = parser.parse_args()

    try:
        update_realm_lifetimes(
            issuer=args.issuer,
            ca_file=args.ca_file,
            namespace=args.namespace,
            keycloak_name=args.keycloak_name,
            access_token_lifespan=args.access_token_lifespan,
            client_session_max_lifespan=args.client_session_max_lifespan,
        )
    except (
        OSError,
        ValueError,
        RuntimeError,
        subprocess.SubprocessError,
        KeyError,
        json.JSONDecodeError,
    ) as error:
        print(
            f"ERROR: unable to update OpenShell OIDC realm lifetimes: {error}",
            file=sys.stderr,
        )
        return 1

    print(
        "Updated OpenShell OIDC realm lifetimes "
        f"(access token={args.access_token_lifespan}s, "
        f"client session={args.client_session_max_lifespan}s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
