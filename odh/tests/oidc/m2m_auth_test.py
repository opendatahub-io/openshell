# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Fork-only M2M (client-credentials) coverage for the ODH OIDC lane.

Validates the M2M plan items without duplicating the server-side
issuer/audience/expiry/JWKS validation:

* ``openshell-ci`` token carries the expected issuer, audience, a subject
  distinct from all interactive users, the ``openshell-user`` role and no
  admin role.
* A valid M2M bearer can use an allowed workspace operation after membership
  is granted, but remains barred from administrative operations.
* A client-credentials grant with an incorrect secret is rejected without
  printing the credential material.

Skip condition: ``OPENSHELL_E2E_OIDC=1`` must be set (the ODH OIDC lane
does; the normal Python lane keeps it disabled). Credentials are provided
by ``odh/tests/oidc/oidc_credentials_plugin.py`` from the per-run
environment, so this file never carries a default secret.
"""

from __future__ import annotations

import contextlib
import os
from typing import Any

import grpc
import pytest
from _oidc_test_helpers import audience_contains, decode_claims
from helpers import extract_sub, get_ci_token, get_token, stub_with_token

from openshell._proto import datamodel_pb2, openshell_pb2

pytestmark = pytest.mark.skipif(
    os.environ.get("OPENSHELL_E2E_OIDC") != "1",
    reason="OIDC e2e tests disabled (set OPENSHELL_E2E_OIDC=1)",
)

WS_M2M = "e2e-oidc-m2m"


def _admin_token() -> str:
    return get_token("admin@test", "admin", scopes="openid openshell:all")


def _ci_token() -> str:
    return get_ci_token()


def _assert_secret_not_leaked(exc: BaseException, bad_secret: str) -> None:
    message = f"{type(exc).__name__}: {exc}"
    assert bad_secret not in message, "failed grant leaked the credential material"
    details = getattr(exc, "details", lambda: "")()
    if isinstance(details, str):
        assert bad_secret not in details, (
            "failed grant leaked the credential material in details"
        )


class TestM2MClientCredentials:
    """Machine-to-machine authentication for ``openshell-ci``."""

    @pytest.fixture(scope="class")
    def admin_ctx(self) -> Any:
        token = _admin_token()
        return stub_with_token(token)

    @pytest.fixture(scope="class")
    def workspace(self, admin_ctx: Any) -> Any:
        stub, metadata = admin_ctx
        with contextlib.suppress(grpc.RpcError):
            stub.DeleteWorkspace(
                openshell_pb2.DeleteWorkspaceRequest(name=WS_M2M),
                metadata=metadata,
            )
        stub.CreateWorkspace(
            openshell_pb2.CreateWorkspaceRequest(name=WS_M2M),
            metadata=metadata,
        )
        yield WS_M2M
        with contextlib.suppress(grpc.RpcError):
            stub.DeleteWorkspace(
                openshell_pb2.DeleteWorkspaceRequest(name=WS_M2M),
                metadata=metadata,
            )

    def test_ci_token_claims_match_gateway_contract(self) -> None:
        """M2M token: issuer, audience, distinct subject, user role, no admin."""
        issuer = os.environ.get("OPENSHELL_E2E_OIDC_ISSUER") or os.environ.get(
            "OIDC_IDENTITY_ISSUER"
        )
        assert issuer, "issuer must be supplied by the ODH OIDC fixture"
        ci_token = _ci_token()
        ci_claims = decode_claims(ci_token)
        assert ci_claims.get("iss") == issuer
        assert audience_contains(ci_claims, "openshell-cli"), (
            f"audience missing in {ci_claims.get('aud')!r}"
        )

        ci_sub = ci_claims.get("sub")
        assert isinstance(ci_sub, str) and ci_sub

        admin_sub = extract_sub(
            get_token("admin@test", "admin", scopes="openid openshell:all")
        )
        user_sub = extract_sub(
            get_token("user@test", "user", scopes="openid openshell:all")
        )
        user_b_sub = extract_sub(
            get_token("user-b@test", "user-b", scopes="openid openshell:all")
        )
        assert ci_sub not in {admin_sub, user_sub, user_b_sub}

        roles = (
            ci_claims.get("realm_access", {}).get("roles", [])
            if isinstance(ci_claims.get("realm_access"), dict)
            else []
        )
        assert isinstance(roles, list)
        assert "openshell-user" in roles
        assert "openshell-admin" not in roles

    def test_ci_bearer_allowed_operation_after_membership_and_denied_admin(
        self, admin_ctx: Any, workspace: str
    ) -> None:
        """Valid M2M bearer: allowed workspace op after membership, admin op denied."""
        admin_stub, admin_md = admin_ctx
        ci_token = _ci_token()
        ci_sub = decode_claims(ci_token).get("sub")
        assert isinstance(ci_sub, str) and ci_sub
        ci_stub, ci_md = stub_with_token(ci_token)

        # Non-member first: filtered from ListWorkspaces (same contract as upstream).
        resp = ci_stub.ListWorkspaces(
            openshell_pb2.ListWorkspacesRequest(), metadata=ci_md
        )
        assert workspace not in [w.metadata.name for w in resp.workspaces]

        admin_stub.AddWorkspaceMember(
            openshell_pb2.AddWorkspaceMemberRequest(
                workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace),
                principal_subject=ci_sub,
                role=openshell_pb2.WORKSPACE_ROLE_USER,
            ),
            metadata=admin_md,
        )
        try:
            resp = ci_stub.ListWorkspaces(
                openshell_pb2.ListWorkspacesRequest(), metadata=ci_md
            )
            assert workspace in [w.metadata.name for w in resp.workspaces]

            ci_stub.ListSandboxes(
                openshell_pb2.ListSandboxesRequest(
                    workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace)
                ),
                metadata=ci_md,
            )

            with pytest.raises(grpc.RpcError) as exc_info:
                ci_stub.CreateProvider(
                    openshell_pb2.CreateProviderRequest(
                        workspace_scope=datamodel_pb2.WorkspaceSelector(
                            workspace=workspace
                        ),
                        provider=datamodel_pb2.Provider(
                            metadata=datamodel_pb2.ObjectMeta(
                                name="ci-blocked", workspace=workspace
                            ),
                            type="claude-code",
                            credentials={"ANTHROPIC_API_KEY": "v"},
                        ),
                    ),
                    metadata=ci_md,
                )
            assert exc_info.value.code() == grpc.StatusCode.PERMISSION_DENIED
            assert "workspace role 'admin' required" in exc_info.value.details()
        finally:
            with contextlib.suppress(grpc.RpcError):
                admin_stub.RemoveWorkspaceMember(
                    openshell_pb2.RemoveWorkspaceMemberRequest(
                        workspace_scope=datamodel_pb2.WorkspaceSelector(
                            workspace=workspace
                        ),
                        principal_subject=ci_sub,
                    ),
                    metadata=admin_md,
                )

    def test_ci_grant_with_wrong_secret_is_rejected_without_leak(self) -> None:
        """Incorrect client secret: grant rejected, credential not printed."""
        bad_secret = "wrong-secret-for-test-only-not-a-real-credential"
        with pytest.raises(Exception) as exc_info:
            get_ci_token(client_secret=bad_secret)
        _assert_secret_not_leaked(exc_info.value, bad_secret)
