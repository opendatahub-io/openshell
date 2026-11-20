#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Validate the redacted Keycloak identity contract for the ODH OIDC lane.

Requests one access token per fixture principal directly from the issuer,
decodes the JWT payload in memory, and checks the claims the gateway's OIDC
authorization depends on: issuer, distinct subjects, realm roles, and the
expected scope. It then exercises the two remaining identity-provider
contracts the Python suite depends on — a token carrying the specific
sandbox scopes (the scopes-claim enforcement path) and the openshell-ci
client-credentials grant (audience and service-account roles) — so a
failure in any of them is reported as an identity-provider failure rather
than surfacing later as a generic pytest or urllib error. The gateway side
is validated separately (deployment readiness probes and the authenticated
administrator session). No token is persisted; the evidence summary records
only stable labels, role/scope data, and non-reversible subject
fingerprints.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import NoReturn

CI_CLIENT_ID = "openshell-ci"
GATEWAY_AUDIENCE = "openshell-cli"
SCOPED_TOKEN_SCOPES = ("sandbox:read", "sandbox:write")


def fail(message: str) -> NoReturn:
    """Exit without exposing an access token or credential."""
    print(f"identity-provider fixture validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def request_token(
    *,
    label: str,
    body: dict[str, str],
    token_endpoint: str,
    tls_context: ssl.SSLContext,
) -> str:
    """Request a fixture access token without persisting it."""
    request = urllib.request.Request(
        token_endpoint, data=urllib.parse.urlencode(body).encode()
    )
    try:
        with urllib.request.urlopen(
            request, context=tls_context, timeout=15
        ) as response:
            return json.loads(response.read())["access_token"]
    except Exception as error:
        fail(f"could not obtain a token for {label}: {type(error).__name__}")


def decode_claims(*, label: str, token: str) -> dict[str, object]:
    """Decode a JWT payload without persisting the token."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception as error:
        fail(
            f"token for {label} did not contain a readable JWT payload: {type(error).__name__}"
        )


def token_claims(
    *,
    label: str,
    username: str,
    password: str,
    token_endpoint: str,
    expected_scope: str,
    tls_context: ssl.SSLContext,
) -> dict[str, object]:
    """Request and decode a password-grant fixture access token."""
    return decode_claims(
        label=label,
        token=request_token(
            label=label,
            body={
                "grant_type": "password",
                "client_id": "openshell-cli",
                "username": username,
                "password": password,
                "scope": f"openid {expected_scope}",
            },
            token_endpoint=token_endpoint,
            tls_context=tls_context,
        ),
    )


def readable_roles(*, label: str, claims: dict[str, object]) -> list[str]:
    realm_access = claims.get("realm_access")
    roles = realm_access.get("roles", []) if isinstance(realm_access, dict) else []
    if not isinstance(roles, list) or not all(isinstance(role, str) for role in roles):
        fail(f"token for {label} has no readable realm roles")
    return roles


def readable_scopes(*, label: str, claims: dict[str, object]) -> list[str]:
    scope_claim = claims.get("scope")
    if not isinstance(scope_claim, str):
        fail(f"token for {label} has no readable scope claim")
    return scope_claim.split()


def audience_contains(claims: dict[str, object], audience: str) -> bool:
    claim = claims.get("aud")
    if isinstance(claim, str):
        return audience in claim.split()
    if isinstance(claim, list):
        return audience in claim
    return False


def main() -> None:
    """Validate Keycloak claims and write a credential-free evidence summary."""
    issuer = os.environ["OIDC_IDENTITY_ISSUER"]
    expected_scope = os.environ["OIDC_IDENTITY_SCOPE"]
    token_endpoint = f"{issuer}/protocol/openid-connect/token"
    tls_context = ssl.create_default_context(cafile=os.environ["OIDC_IDENTITY_CA_FILE"])
    admin_role = os.environ["OIDC_IDENTITY_ADMIN_ROLE"]
    user_role = os.environ["OIDC_IDENTITY_USER_ROLE"]
    ci_client_secret = os.environ["OIDC_IDENTITY_CI_CLIENT_SECRET"]
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

        roles = readable_roles(label=label, claims=claims)
        if user_role not in roles:
            fail(f"token for {label} is missing required user role")
        if is_admin != (admin_role in roles):
            fail(f"token for {label} has an unexpected platform-admin role")

        scopes = readable_scopes(label=label, claims=claims)
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

    # The scopes-claim enforcement path: an admin token requested with the
    # specific sandbox scopes must carry exactly those optional scopes, or
    # every scopes test in the suite fails with unclassified errors.
    scoped_claims = token_claims(
        label="admin-scoped",
        username="admin@test",
        password=os.environ["OIDC_IDENTITY_ADMIN_PASSWORD"],
        token_endpoint=token_endpoint,
        expected_scope=" ".join(SCOPED_TOKEN_SCOPES),
        tls_context=tls_context,
    )
    scoped = readable_scopes(label="admin-scoped", claims=scoped_claims)
    for scope in SCOPED_TOKEN_SCOPES:
        if scope not in scoped:
            fail(f"scoped admin token is missing optional scope {scope}")

    # The CI automation contract: the confidential client must complete the
    # client-credentials grant and mint a service-account token carrying the
    # gateway audience and the default user role.
    ci_claims = decode_claims(
        label="ci-client",
        token=request_token(
            label="ci-client",
            body={
                "grant_type": "client_credentials",
                "client_id": CI_CLIENT_ID,
                "client_secret": ci_client_secret,
            },
            token_endpoint=token_endpoint,
            tls_context=tls_context,
        ),
    )
    ci_subject = ci_claims.get("sub")
    if not isinstance(ci_subject, str) or not ci_subject:
        fail("token for ci-client has no subject claim")
    if ci_subject in subjects:
        fail("token for ci-client does not have a distinct subject")
    if not audience_contains(ci_claims, GATEWAY_AUDIENCE):
        fail(f"token for ci-client is missing the {GATEWAY_AUDIENCE} audience")
    ci_roles = readable_roles(label="ci-client", claims=ci_claims)
    if user_role not in ci_roles:
        fail("token for ci-client is missing the default user role")
    summary.append(
        {
            "principal": "ci-client",
            "subject_sha256_12": hashlib.sha256(ci_subject.encode()).hexdigest()[:12],
            "roles": sorted(ci_roles),
            "scopes": sorted(readable_scopes(label="ci-client", claims=ci_claims)),
        }
    )

    with Path(os.environ["OIDC_IDENTITY_SUMMARY"]).open(
        "w", encoding="utf-8"
    ) as output:
        json.dump(
            {"issuer": issuer, "principals": summary}, output, indent=2, sort_keys=True
        )
        output.write("\n")


if __name__ == "__main__":
    main()
