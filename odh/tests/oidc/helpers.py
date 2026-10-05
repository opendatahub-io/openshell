# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Helpers for the ODH OpenShift OIDC session-lifecycle tests."""

from __future__ import annotations

import base64
import json
import os
import urllib.parse
import urllib.request
from pathlib import Path

import grpc

from openshell._proto import openshell_pb2_grpc

KEYCLOAK_REALM = "openshell"


def _required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} is required by the ODH OIDC lifecycle suite")
    return value


def _token_endpoint() -> str:
    return (
        f"{_required_env('OPENSHELL_KEYCLOAK_URL').rstrip('/')}"
        f"/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token"
    )


def _token_request(data: dict[str, str]) -> dict[str, object]:
    """POST token form data without logging fixture credentials or tokens."""
    request = urllib.request.Request(
        _token_endpoint(), data=urllib.parse.urlencode(data).encode()
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read())


def get_token_response(username: str, *, scopes: str) -> dict[str, object]:
    password_env = {
        "admin@test": "OPENSHELL_E2E_OIDC_ADMIN_PASSWORD",
        "user@test": "OPENSHELL_E2E_OIDC_USER_PASSWORD",
        "user-b@test": "OPENSHELL_E2E_OIDC_USER_B_PASSWORD",
    }.get(username)
    if password_env is None:
        raise ValueError(f"no ODH fixture password is configured for {username}")
    return _token_request(
        {
            "grant_type": "password",
            "client_id": "openshell-cli",
            "username": username,
            "password": _required_env(password_env),
            "scope": scopes,
        }
    )


def refresh_token(token: str) -> dict[str, object]:
    return _token_request(
        {
            "grant_type": "refresh_token",
            "client_id": "openshell-cli",
            "refresh_token": token,
        }
    )


def extract_jwt_claims(token: str) -> dict[str, object]:
    payload = token.split(".")[1]
    padded = payload + "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(padded))


def extract_sub(token: str) -> str:
    return str(extract_jwt_claims(token)["sub"])


def stub_with_token(
    token: str,
) -> tuple[openshell_pb2_grpc.OpenShellStub, list[tuple[str, str]]]:
    endpoint = _required_env("OPENSHELL_E2E_OIDC_GATEWAY_ENDPOINT")
    parsed = urllib.parse.urlparse(endpoint)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 443
    mtls_dir = Path(_required_env("OPENSHELL_E2E_GATEWAY_MTLS_DIR"))
    credentials = grpc.ssl_channel_credentials(
        root_certificates=(mtls_dir / "ca.crt").read_bytes(),
        private_key=(mtls_dir / "tls.key").read_bytes(),
        certificate_chain=(mtls_dir / "tls.crt").read_bytes(),
    )
    channel = grpc.secure_channel(f"{host}:{port}", credentials)
    return openshell_pb2_grpc.OpenShellStub(channel), [
        ("authorization", f"Bearer {token}")
    ]
