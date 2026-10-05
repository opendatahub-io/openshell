# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Validate the redacted Keycloak identity contract for the ODH OIDC lane."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request


def fail(message: str) -> None:
    """Exit without exposing an access token or credential."""
    print(f"identity-provider fixture validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def token_claims(
    *,
    label: str,
    username: str,
    password: str,
    token_endpoint: str,
    expected_scope: str,
    tls_context: ssl.SSLContext,
) -> dict[str, object]:
    """Request and decode a fixture access token without persisting it."""
    body = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": "openshell-cli",
            "username": username,
            "password": password,
            "scope": f"openid {expected_scope}",
        }
    ).encode()
    request = urllib.request.Request(token_endpoint, data=body)
    try:
        with urllib.request.urlopen(request, context=tls_context, timeout=15) as response:
            token = json.loads(response.read())["access_token"]
    except Exception as error:
        fail(f"could not obtain a token for {label}: {type(error).__name__}")

    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception as error:
        fail(f"token for {label} did not contain a readable JWT payload: {type(error).__name__}")


def main() -> None:
    """Validate Keycloak claims and write a credential-free evidence summary."""
    issuer = os.environ["OIDC_IDENTITY_ISSUER"]
    expected_scope = os.environ["OIDC_IDENTITY_SCOPE"]
    token_endpoint = f"{issuer}/protocol/openid-connect/token"
    tls_context = ssl.create_default_context(cafile=os.environ["OIDC_IDENTITY_CA_FILE"])
    admin_role = os.environ["OIDC_IDENTITY_ADMIN_ROLE"]
    user_role = os.environ["OIDC_IDENTITY_USER_ROLE"]
    principals = (
        ("admin", "admin@test", os.environ["OIDC_IDENTITY_ADMIN_PASSWORD"], True),
        ("user-a", "user@test", os.environ["OIDC_IDENTITY_USER_PASSWORD"], False),
        ("user-b", "user-b@test", os.environ["OIDC_IDENTITY_USER_B_PASSWORD"], False),
    )

    subjects: set[str] = set()
    summary: list[dict[str, object]] = []
    for label, username, password, is_admin in principals:
        claims = token_claims(
            label=label,
            username=username,
            password=password,
            token_endpoint=token_endpoint,
            expected_scope=expected_scope,
            tls_context=tls_context,
        )
        if claims.get("iss") != issuer:
            fail(f"token for {label} has an unexpected issuer")
        subject = claims.get("sub")
        if not isinstance(subject, str) or not subject:
            fail(f"token for {label} has no subject claim")
        if subject in subjects:
            fail(f"token for {label} does not have a distinct subject")
        subjects.add(subject)

        realm_access = claims.get("realm_access")
        roles = realm_access.get("roles", []) if isinstance(realm_access, dict) else []
        if not isinstance(roles, list) or not all(isinstance(role, str) for role in roles):
            fail(f"token for {label} has no readable realm roles")
        if user_role not in roles:
            fail(f"token for {label} is missing required user role")
        if is_admin != (admin_role in roles):
            fail(f"token for {label} has an unexpected platform-admin role")

        scopes = claims.get("scope", "").split()
        if expected_scope not in scopes:
            fail(f"token for {label} is missing required scope")
        summary.append(
            {
                "principal": label,
                "subject_sha256_12": hashlib.sha256(subject.encode()).hexdigest()[:12],
                "roles": sorted(roles),
                "scopes": sorted(scopes),
            }
        )

    with open(os.environ["OIDC_IDENTITY_SUMMARY"], "w", encoding="utf-8") as output:
        json.dump({"issuer": issuer, "principals": summary}, output, indent=2, sort_keys=True)
        output.write("\n")


if __name__ == "__main__":
    main()
