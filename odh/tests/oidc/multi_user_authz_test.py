# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Fork-only multi-user workspace-authorization coverage.

The upstream ``e2e/python/oidc`` suite qualifies two subjects
(``admin@test`` and ``user@test``). This fork-only module completes the
multi-user evidence against the same fixture: a third distinct
Keycloak-issued subject (``user-b@test``), non-member isolation between
two ordinary users, and the provider-management boundary for a Workspace
User member (create, update, and delete are reserved to Workspace
Admins).

Skip condition: set OPENSHELL_E2E_OIDC=1 to enable (the ODH OIDC lane
does; the normal Python lane keeps it disabled).
"""

from __future__ import annotations

import contextlib
import os
from typing import Any

import grpc
import pytest
from helpers import extract_sub, get_token, stub_with_token

from openshell._proto import datamodel_pb2, openshell_pb2

pytestmark = pytest.mark.skipif(
    os.environ.get("OPENSHELL_E2E_OIDC") != "1",
    reason="OIDC e2e tests disabled (set OPENSHELL_E2E_OIDC=1)",
)

WS = "e2e-oidc-multi-user"


def _admin_token() -> str:
    return get_token("admin@test", "admin", scopes="openid openshell:all")


def _user_token() -> str:
    return get_token("user@test", "user", scopes="openid openshell:all")


def _user_b_token() -> str:
    return get_token("user-b@test", "user-b", scopes="openid openshell:all")


def _add_member(
    stub: Any,
    metadata: list[tuple[str, str]],
    workspace: str,
    subject: str,
    role: int,
) -> None:
    stub.AddWorkspaceMember(
        openshell_pb2.AddWorkspaceMemberRequest(
            workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace),
            principal_subject=subject,
            role=role,
        ),
        metadata=metadata,
    )


def _remove_member(
    stub: Any,
    metadata: list[tuple[str, str]],
    workspace: str,
    subject: str,
) -> None:
    with contextlib.suppress(grpc.RpcError):
        stub.RemoveWorkspaceMember(
            openshell_pb2.RemoveWorkspaceMemberRequest(
                workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace),
                principal_subject=subject,
            ),
            metadata=metadata,
        )


def _assert_workspace_admin_denial(
    error: grpc.RpcError,
    workspace: str,
    subject: str,
    rpc_name: str,
) -> None:
    assert error.code() == grpc.StatusCode.PERMISSION_DENIED, (
        f"{rpc_name}: expected PERMISSION_DENIED, got {error.code()}"
    )
    details = error.details()
    assert f"workspace role 'admin' required in workspace '{workspace}'" in details, (
        f"{rpc_name}: denial came from the wrong authorization layer: {details}"
    )
    command = (
        "openshell workspace member add "
        f"--workspace '{workspace}' --subject '{subject}' --role admin"
    )
    assert command in details, (
        f"{rpc_name}: denial omitted the admin remediation command: {details}"
    )


def _assert_non_member_denial(
    error: grpc.RpcError,
    workspace: str,
    subject: str,
    rpc_name: str,
) -> None:
    assert error.code() == grpc.StatusCode.PERMISSION_DENIED, (
        f"{rpc_name}: expected PERMISSION_DENIED, got {error.code()}"
    )
    details = error.details()
    assert f"not a member of workspace '{workspace}'" in details, (
        f"{rpc_name}: denial came from the wrong authorization layer: {details}"
    )
    command = (
        "openshell workspace member add "
        f"--workspace '{workspace}' --subject '{subject}' --role user"
    )
    assert command in details, (
        f"{rpc_name}: denial omitted the actionable membership command: {details}"
    )


@pytest.fixture(scope="module")
def admin_ctx() -> Any:
    token = _admin_token()
    return stub_with_token(token)


@pytest.fixture(scope="module")
def workspace(admin_ctx: Any) -> Any:
    """Create a module-scoped test workspace and tear it down afterwards."""
    stub, metadata = admin_ctx
    with contextlib.suppress(grpc.RpcError):
        stub.DeleteWorkspace(
            openshell_pb2.DeleteWorkspaceRequest(name=WS),
            metadata=metadata,
        )
    stub.CreateWorkspace(
        openshell_pb2.CreateWorkspaceRequest(name=WS),
        metadata=metadata,
    )
    yield WS
    with contextlib.suppress(grpc.RpcError):
        stub.DeleteWorkspace(
            openshell_pb2.DeleteWorkspaceRequest(name=WS),
            metadata=metadata,
        )


class TestMultiUserWorkspaceAuthorization:
    """Three distinct authenticated subjects and the provider boundary."""

    def test_third_subject_isolated_until_membership(
        self,
        admin_ctx: Any,
        workspace: str,
    ) -> None:
        """user-b is a distinct subject, rejected until granted membership."""
        admin_stub, admin_md = admin_ctx

        user_token = _user_token()
        user_sub = extract_sub(user_token)
        user_stub, user_md = stub_with_token(user_token)

        user_b_token = _user_b_token()
        user_b_sub = extract_sub(user_b_token)
        assert user_b_sub != user_sub, "user and user-b must be distinct subjects"
        user_b_stub, user_b_md = stub_with_token(user_b_token)

        with pytest.raises(grpc.RpcError) as exc_info:
            user_b_stub.ListSandboxes(
                openshell_pb2.ListSandboxesRequest(
                    workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace)
                ),
                metadata=user_b_md,
            )
        _assert_non_member_denial(
            exc_info.value, workspace, user_b_sub, "ListSandboxes"
        )

        _add_member(
            admin_stub, admin_md, workspace, user_sub, openshell_pb2.WORKSPACE_ROLE_USER
        )
        _add_member(
            admin_stub,
            admin_md,
            workspace,
            user_b_sub,
            openshell_pb2.WORKSPACE_ROLE_USER,
        )
        try:
            user_stub.ListSandboxes(
                openshell_pb2.ListSandboxesRequest(
                    workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace)
                ),
                metadata=user_md,
            )
            user_b_stub.ListSandboxes(
                openshell_pb2.ListSandboxesRequest(
                    workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace)
                ),
                metadata=user_b_md,
            )
        finally:
            _remove_member(admin_stub, admin_md, workspace, user_sub)
            _remove_member(admin_stub, admin_md, workspace, user_b_sub)

    def test_workspace_user_cannot_manage_providers(
        self,
        admin_ctx: Any,
        workspace: str,
    ) -> None:
        """A Workspace User member cannot create, update, or delete providers."""
        admin_stub, admin_md = admin_ctx

        user_token = _user_token()
        user_sub = extract_sub(user_token)
        user_stub, user_md = stub_with_token(user_token)

        user_b_token = _user_b_token()
        user_b_sub = extract_sub(user_b_token)
        user_b_stub, user_b_md = stub_with_token(user_b_token)

        provider_name = "e2e-oidc-user-managed"
        with contextlib.suppress(grpc.RpcError):
            admin_stub.DeleteProvider(
                openshell_pb2.DeleteProviderRequest(
                    name=provider_name,
                    workspace_scope=datamodel_pb2.WorkspaceSelector(
                        workspace=workspace
                    ),
                ),
                metadata=admin_md,
            )
        admin_stub.CreateProvider(
            openshell_pb2.CreateProviderRequest(
                workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=workspace),
                provider=datamodel_pb2.Provider(
                    metadata=datamodel_pb2.ObjectMeta(
                        name=provider_name, workspace=workspace
                    ),
                    type="claude-code",
                    credentials={"ANTHROPIC_API_KEY": "v"},
                ),
            ),
            metadata=admin_md,
        )
        _add_member(
            admin_stub, admin_md, workspace, user_sub, openshell_pb2.WORKSPACE_ROLE_USER
        )
        _add_member(
            admin_stub,
            admin_md,
            workspace,
            user_b_sub,
            openshell_pb2.WORKSPACE_ROLE_USER,
        )
        try:
            with pytest.raises(grpc.RpcError) as exc_info:
                user_stub.UpdateProvider(
                    openshell_pb2.UpdateProviderRequest(
                        workspace_scope=datamodel_pb2.WorkspaceSelector(
                            workspace=workspace
                        ),
                        provider=datamodel_pb2.Provider(
                            metadata=datamodel_pb2.ObjectMeta(
                                name=provider_name, workspace=workspace
                            ),
                            type="claude-code",
                            credentials={"ANTHROPIC_API_KEY": "v"},
                        ),
                    ),
                    metadata=user_md,
                )
            _assert_workspace_admin_denial(
                exc_info.value, workspace, user_sub, "UpdateProvider"
            )

            with pytest.raises(grpc.RpcError) as exc_info:
                user_b_stub.DeleteProvider(
                    openshell_pb2.DeleteProviderRequest(
                        name=provider_name,
                        workspace_scope=datamodel_pb2.WorkspaceSelector(
                            workspace=workspace
                        ),
                    ),
                    metadata=user_b_md,
                )
            _assert_workspace_admin_denial(
                exc_info.value, workspace, user_b_sub, "DeleteProvider"
            )

            with pytest.raises(grpc.RpcError) as exc_info:
                user_stub.CreateProvider(
                    openshell_pb2.CreateProviderRequest(
                        workspace_scope=datamodel_pb2.WorkspaceSelector(
                            workspace=workspace
                        ),
                        provider=datamodel_pb2.Provider(
                            metadata=datamodel_pb2.ObjectMeta(
                                name="user-blocked", workspace=workspace
                            ),
                            type="claude-code",
                            credentials={"ANTHROPIC_API_KEY": "v"},
                        ),
                    ),
                    metadata=user_md,
                )
            _assert_workspace_admin_denial(
                exc_info.value, workspace, user_sub, "CreateProvider"
            )
        finally:
            with contextlib.suppress(grpc.RpcError):
                admin_stub.DeleteProvider(
                    openshell_pb2.DeleteProviderRequest(
                        name=provider_name,
                        workspace_scope=datamodel_pb2.WorkspaceSelector(
                            workspace=workspace
                        ),
                    ),
                    metadata=admin_md,
                )
            _remove_member(admin_stub, admin_md, workspace, user_sub)
            _remove_member(admin_stub, admin_md, workspace, user_b_sub)
