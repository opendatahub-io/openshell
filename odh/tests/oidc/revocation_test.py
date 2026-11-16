# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Fork-only revocation coverage (OpenShift lane only — SKIPPED on Docker).

Dedicated ephemeral client ``openshell-revocation-test`` + limited admin
identity ``revocation@test`` inside the disposable realm (provisioned only
by ``odh/scripts/oidc-fixture/setup.sh`` for ``mise run e2e:odh:oidc``):

* valid token → allowed operation after membership,
* disable client via Admin API → new grants fail,
* already-issued token (still unexpired) continues to authenticate — expiry is
  covered by the Gateway's existing server-side tests.

Credentials are per-run env only (never in fixture.env/state.env/reports).
The Docker lane explicitly disables this test; only the OpenShift entrypoint
sets ``OPENSHELL_E2E_OIDC_REVOCATION_ENABLED=1`` after fixture setup.
"""

from __future__ import annotations

import contextlib
import json
import os
import ssl
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

import grpc
import pytest
from _oidc_test_helpers import audience_contains, decode_claims
from helpers import extract_sub, get_ci_token, get_token, keycloak_url, stub_with_token

from openshell._proto import datamodel_pb2, openshell_pb2

pytestmark = [
    pytest.mark.skipif(
        os.environ.get("OPENSHELL_E2E_OIDC") != "1",
        reason="OIDC e2e tests disabled (set OPENSHELL_E2E_OIDC=1)",
    ),
    pytest.mark.skipif(
        os.environ.get("OPENSHELL_E2E_OIDC_REVOCATION_ENABLED") != "1",
        reason="Revocation is enabled only by the OpenShift OIDC fixture",
    ),
]

REVOCATION_CLIENT_ID = "openshell-revocation-test"
WS_REVOCATION = "e2e-oidc-revocation"
REALM = "openshell"


def _revocation_available() -> bool:
    return bool(
        os.environ.get("OPENSHELL_E2E_OIDC_REVOCATION_CLIENT_SECRET")
        and os.environ.get("OPENSHELL_E2E_OIDC_REVOCATION_USER_PASSWORD")
    )


def _admin_token() -> str:
    return get_token("admin@test", "admin", scopes="openid openshell:all")


def _keycloak_tls_context() -> ssl.SSLContext:
    """Use the fixture's CA when present (OpenShift Route TLS)."""
    ca_file = os.environ.get("OPENSHELL_E2E_OIDC_CA_CERT_FILE") or os.environ.get(
        "OIDC_IDENTITY_CA_FILE"
    )
    if ca_file and Path(ca_file).exists():
        return ssl.create_default_context(cafile=ca_file)
    return ssl.create_default_context()


def _admin_api_disable_client(admin_access_token: str, client_id: str) -> None:
    """Disable a client via Keycloak Admin API (realm-scoped).

    Uses ``revocation@test``'s token which has only
    ``openshell-revocation-manager`` inside this disposable realm.
    On real Keycloak this needs ``manage-clients`` on the realm-management
    client; the disposable realm maps it from the custom role. Failure is
    explicit — don't silently skip revocation.
    """
    base = keycloak_url().rstrip("/")
    tls_ctx = _keycloak_tls_context()

    # 1. Resolve internal UUID for the clientId.
    list_url = (
        f"{base}/admin/realms/{REALM}/clients?clientId={urllib.parse.quote(client_id)}"
    )
    req = urllib.request.Request(list_url)
    req.add_header("Authorization", f"Bearer {admin_access_token}")
    with urllib.request.urlopen(req, context=tls_ctx, timeout=15) as resp:
        clients = json.loads(resp.read())
    if not clients:
        pytest.fail(f"Admin API: client {client_id} not found in the OpenShift fixture")
    internal_id = clients[0]["id"]

    # 2. Disable the client.
    update_url = (
        f"{base}/admin/realms/{REALM}/clients/{urllib.parse.quote(internal_id)}"
    )
    body = json.dumps({"enabled": False}).encode()
    req = urllib.request.Request(update_url, data=body, method="PUT")
    req.add_header("Authorization", f"Bearer {admin_access_token}")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, context=tls_ctx, timeout=15) as resp:
        if resp.status not in (204, 200):
            pytest.fail(f"Admin API disable returned {resp.status}")

    # 3. Poll that new grants are rejected (Keycloak may be eventually consistent).
    tls_ctx2 = _keycloak_tls_context()
    issuer = (
        os.environ.get("OPENSHELL_E2E_OIDC_ISSUER")
        or os.environ.get("OIDC_IDENTITY_ISSUER")
        or f"{base}/realms/{REALM}"
    )
    token_endpoint = f"{issuer}/protocol/openid-connect/token"
    rev_secret = os.environ["OPENSHELL_E2E_OIDC_REVOCATION_CLIENT_SECRET"]
    for _ in range(10):
        try:
            data = urllib.parse.urlencode(
                {
                    "grant_type": "client_credentials",
                    "client_id": client_id,
                    "client_secret": rev_secret,
                }
            ).encode()
            treq = urllib.request.Request(token_endpoint, data=data)
            with urllib.request.urlopen(treq, context=tls_ctx2, timeout=10) as _:
                pass
        except Exception as exc:
            # New grants now fail — good. Don't leak the secret in the assertion.
            msg = f"{type(exc).__name__}: {exc}"
            assert rev_secret not in msg
            return
        time.sleep(0.5)
    pytest.fail("Admin API disabled the client but new grants still succeeded")


class TestRevocation:
    """Ephemeral client revocation; already-issued JWT stays valid until expiry."""

    @pytest.fixture(scope="class")
    def admin_ctx(self) -> Any:
        if not _revocation_available():
            pytest.fail(
                "OpenShift revocation is enabled but its per-run client secret or user password is missing"
            )
        token = _admin_token()
        return stub_with_token(token)

    @pytest.fixture(scope="class")
    def workspace(self, admin_ctx: Any) -> Any:
        stub, metadata = admin_ctx
        with contextlib.suppress(grpc.RpcError):
            stub.DeleteWorkspace(
                openshell_pb2.DeleteWorkspaceRequest(name=WS_REVOCATION),
                metadata=metadata,
            )
        stub.CreateWorkspace(
            openshell_pb2.CreateWorkspaceRequest(name=WS_REVOCATION),
            metadata=metadata,
        )
        yield WS_REVOCATION
        with contextlib.suppress(grpc.RpcError):
            stub.DeleteWorkspace(
                openshell_pb2.DeleteWorkspaceRequest(name=WS_REVOCATION),
                metadata=metadata,
            )

    def test_revoked_client_new_grants_rejected_existing_token_still_valid(
        self, admin_ctx: Any, workspace: str
    ) -> None:
        assert _revocation_available(), "OpenShift revocation credentials are missing"
        admin_stub, admin_md = admin_ctx
        revocation_secret = os.environ[
            "OPENSHELL_E2E_OIDC_REVOCATION_CLIENT_SECRET"
        ]

        # 1. Valid token before revocation — prove it can do an allowed op.
        rev_token_before = get_ci_token(
            client_id=REVOCATION_CLIENT_ID,
            client_secret=revocation_secret,
        )
        rev_claims = decode_claims(rev_token_before)
        assert audience_contains(rev_claims, "openshell-cli")
        assert rev_claims.get("sub") not in {
            extract_sub(
                get_token("admin@test", "admin", scopes="openid openshell:all")
            ),
            extract_sub(get_token("user@test", "user", scopes="openid openshell:all")),
        }
        rev_sub = rev_claims["sub"]
        rev_stub_before, rev_md_before = stub_with_token(rev_token_before)

        # Non-member filtered, then allowed after membership.
        resp = rev_stub_before.ListWorkspaces(
            openshell_pb2.ListWorkspacesRequest(), metadata=rev_md_before
        )
        assert workspace not in [w.metadata.name for w in resp.workspaces]
        admin_stub.AddWorkspaceMember(
            openshell_pb2.AddWorkspaceMemberRequest(
                workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace),
                principal_subject=rev_sub,
                role=openshell_pb2.WORKSPACE_ROLE_USER,
            ),
            metadata=admin_md,
        )
        try:
            rev_stub_before.ListSandboxes(
                openshell_pb2.ListSandboxesRequest(
                    workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace)
                ),
                metadata=rev_md_before,
            )

            # 2. Disable the client via Admin API using the limited identity.
            revocation_admin_token = get_token(
                "revocation@test",
                os.environ["OPENSHELL_E2E_OIDC_REVOCATION_USER_PASSWORD"],
                scopes="openid openshell:all kc-admin-api",
            )
            admin_claims = decode_claims(revocation_admin_token)
            assert "kc-admin-api" in admin_claims.get("scope", "").split()
            assert audience_contains(
                admin_claims,
                f"{keycloak_url().rstrip('/')}/admin/realms/{REALM}",
            )
            _admin_api_disable_client(revocation_admin_token, REVOCATION_CLIENT_ID)

            # 3. New grants must fail — without leaking the credential.
            with pytest.raises(Exception) as exc_info:
                get_ci_token(
                    client_id=REVOCATION_CLIENT_ID,
                    client_secret=revocation_secret,
                )
            assert revocation_secret not in f"{exc_info.value}"

            # 4. Already-issued token (still unexpired) still authenticates —
            #    the Gateway validates locally; expiry is covered by server tests.
            rev_stub_before.ListSandboxes(
                openshell_pb2.ListSandboxesRequest(
                    workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace)
                ),
                metadata=rev_md_before,
            )
        finally:
            with contextlib.suppress(grpc.RpcError):
                admin_stub.RemoveWorkspaceMember(
                    openshell_pb2.RemoveWorkspaceMemberRequest(
                        workspace_scope=datamodel_pb2.WorkspaceSelector(
                            workspace=workspace
                        ),
                        principal_subject=rev_sub,
                    ),
                    metadata=admin_md,
                )
