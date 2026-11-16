# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Fork-only cross-workspace isolation (downstream).

Two isolated workspaces ``e2e-oidc-iso-a`` / ``b``: ``user@test``
belongs to A, ``user-b@test`` to B. Verifies own-workspace access,
cross-workspace denial/filtering, no side effects on resources, and loss of
access after membership removal. Uses only ``odh/tests/oidc/`` + the ODH
fixture; realm shared file and ``e2e/python/oidc/workspace_authz_test.py``
are untouched. ``CreateProvider`` is not re-asserted here (covered upstream);
``UpdateProvider``/``DeleteProvider`` remain as the downstream
provider-boundary evidence.
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

WS_A = "e2e-oidc-iso-a"
WS_B = "e2e-oidc-iso-b"


def _admin_token() -> str:
    return get_token("admin@test", "admin", scopes="openid openshell:all")


def _user_token() -> str:
    return get_token("user@test", "user", scopes="openid openshell:all")


def _user_b_token() -> str:
    return get_token("user-b@test", "user-b", scopes="openid openshell:all")


def _assert_non_member_denial(
    error: grpc.RpcError, workspace: str, subject: str, _rpc_name: str
) -> None:
    assert error.code() == grpc.StatusCode.PERMISSION_DENIED
    details = error.details()
    assert f"not a member of workspace '{workspace}'" in details, details
    assert (
        f"openshell workspace member add --workspace '{workspace}' --subject '{subject}' --role user"
        in details
    ), details


def _assert_workspace_admin_denial(
    error: grpc.RpcError, workspace: str, subject: str, _rpc_name: str
) -> None:
    assert error.code() == grpc.StatusCode.PERMISSION_DENIED
    details = error.details()
    assert f"workspace role 'admin' required in workspace '{workspace}'" in details, (
        details
    )
    assert (
        f"openshell workspace member add --workspace '{workspace}' --subject '{subject}' --role admin"
        in details
    ), details


class TestCrossWorkspaceIsolation:
    """Two workspaces, two users, no cross-workspace leakage."""

    @pytest.fixture(scope="class")
    def admin_ctx(self) -> Any:
        return stub_with_token(_admin_token())

    @pytest.fixture(scope="class")
    def workspaces(self, admin_ctx: Any) -> Any:
        stub, md = admin_ctx
        created: list[str] = []
        try:
            for ws in (WS_A, WS_B):
                with contextlib.suppress(grpc.RpcError):
                    stub.DeleteWorkspace(
                        openshell_pb2.DeleteWorkspaceRequest(name=ws), metadata=md
                    )
                stub.CreateWorkspace(
                    openshell_pb2.CreateWorkspaceRequest(name=ws), metadata=md
                )
                created.append(ws)
            # Seed one provider per workspace so ListProviders has data and
            # cross-workspace reads have something to leak.
            for ws in created:
                stub.CreateProvider(
                    openshell_pb2.CreateProviderRequest(
                        workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=ws),
                        provider=datamodel_pb2.Provider(
                            metadata=datamodel_pb2.ObjectMeta(
                                name=f"prov-{ws}", workspace=ws
                            ),
                            type="claude-code",
                            credentials={"ANTHROPIC_API_KEY": "v"},
                        ),
                    ),
                    metadata=md,
                )
            yield (WS_A, WS_B)
        finally:
            for ws in created:
                with contextlib.suppress(grpc.RpcError):
                    stub.DeleteProvider(
                        openshell_pb2.DeleteProviderRequest(
                            name=f"prov-{ws}",
                            workspace_scope=datamodel_pb2.WorkspaceSelector(
                                workspace=ws
                            ),
                        ),
                        metadata=md,
                    )
            for ws in created:
                with contextlib.suppress(grpc.RpcError):
                    stub.DeleteWorkspace(
                        openshell_pb2.DeleteWorkspaceRequest(name=ws), metadata=md
                    )

    def test_two_workspaces_isolated_and_membership_revocation(
        self, admin_ctx: Any, workspaces: Any
    ) -> None:
        ws_a, ws_b = workspaces
        admin_stub, admin_md = admin_ctx

        user_sub = extract_sub(_user_token())
        user_b_sub = extract_sub(_user_b_token())
        user_stub, user_md = stub_with_token(_user_token())
        user_b_stub, user_b_md = stub_with_token(_user_b_token())

        # Assign user@test -> A, user-b@test -> B
        admin_stub.AddWorkspaceMember(
            openshell_pb2.AddWorkspaceMemberRequest(
                workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=ws_a),
                principal_subject=user_sub,
                role=openshell_pb2.WORKSPACE_ROLE_USER,
            ),
            metadata=admin_md,
        )
        admin_stub.AddWorkspaceMember(
            openshell_pb2.AddWorkspaceMemberRequest(
                workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=ws_b),
                principal_subject=user_b_sub,
                role=openshell_pb2.WORKSPACE_ROLE_USER,
            ),
            metadata=admin_md,
        )
        try:
            # Own workspace: visible and readable.
            for stub, md, ws in (
                (user_stub, user_md, ws_a),
                (user_b_stub, user_b_md, ws_b),
            ):
                resp = stub.ListWorkspaces(
                    openshell_pb2.ListWorkspacesRequest(), metadata=md
                )
                assert ws in [w.metadata.name for w in resp.workspaces]
                stub.ListSandboxes(
                    openshell_pb2.ListSandboxesRequest(
                        workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=ws)
                    ),
                    metadata=md,
                )
                resp2 = stub.ListProviders(
                    openshell_pb2.ListProvidersRequest(
                        workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=ws)
                    ),
                    metadata=md,
                )
                assert any(p.metadata.name == f"prov-{ws}" for p in resp2.providers)

            # Cross-workspace: filtered from ListWorkspaces, denied on direct reads.
            for stub, md, ws, sub in (
                (user_stub, user_md, ws_b, user_sub),
                (user_b_stub, user_b_md, ws_a, user_b_sub),
            ):
                resp = stub.ListWorkspaces(
                    openshell_pb2.ListWorkspacesRequest(), metadata=md
                )
                assert ws not in [w.metadata.name for w in resp.workspaces]
                with pytest.raises(grpc.RpcError) as exc:
                    stub.GetWorkspace(
                        openshell_pb2.GetWorkspaceRequest(name=ws), metadata=md
                    )
                _assert_non_member_denial(exc.value, ws, sub, "GetWorkspace")
                with pytest.raises(grpc.RpcError) as exc2:
                    stub.GetProvider(
                        openshell_pb2.GetProviderRequest(
                            name=f"prov-{ws}",
                            workspace_scope=datamodel_pb2.WorkspaceSelector(
                                workspace=ws
                            ),
                        ),
                        metadata=md,
                    )
                # Provider reads from a foreign workspace are denied at the
                # membership layer; the exact code is exercised in the upstream
                # suite, so we assert denial without pinning its surface.
                assert exc2.value.code() == grpc.StatusCode.PERMISSION_DENIED

            # No side effects: creating a provider in the foreign workspace is
            # still an admin-only operation, even if the caller is a member
            # elsewhere. We don't assert CreateProvider here (upstream covers it)
            # to avoid duplicating that check; instead assert Update/Delete
            # boundaries which are the downstream-owned signals.
            with pytest.raises(grpc.RpcError) as exc3:
                user_b_stub.UpdateProvider(
                    openshell_pb2.UpdateProviderRequest(
                        workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=ws_a),
                        provider=datamodel_pb2.Provider(
                            metadata=datamodel_pb2.ObjectMeta(
                                name=f"prov-{ws_a}", workspace=ws_a
                            ),
                            type="claude-code",
                            credentials={"ANTHROPIC_API_KEY": "v"},
                        ),
                    ),
                    metadata=user_b_md,
                )
            # Cross-workspace update is non-member before it is admin-related.
            assert exc3.value.code() == grpc.StatusCode.PERMISSION_DENIED

            with pytest.raises(grpc.RpcError) as exc4:
                user_stub.DeleteProvider(
                    openshell_pb2.DeleteProviderRequest(
                        name=f"prov-{ws_b}",
                        workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=ws_b),
                    ),
                    metadata=user_md,
                )
            assert exc4.value.code() == grpc.StatusCode.PERMISSION_DENIED

            # Membership revocation: remove user from A, re-check loss.
            admin_stub.RemoveWorkspaceMember(
                openshell_pb2.RemoveWorkspaceMemberRequest(
                    workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=ws_a),
                    principal_subject=user_sub,
                ),
                metadata=admin_md,
            )
            with pytest.raises(grpc.RpcError) as exc5:
                user_stub.ListSandboxes(
                    openshell_pb2.ListSandboxesRequest(
                        workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=ws_a)
                    ),
                    metadata=user_md,
                )
            _assert_non_member_denial(exc5.value, ws_a, user_sub, "ListSandboxes")
            # B untouched.
            user_b_stub.ListSandboxes(
                openshell_pb2.ListSandboxesRequest(
                    workspace_scope=datamodel_pb2.WorkspaceSelector(workspace=ws_b)
                ),
                metadata=user_b_md,
            )
        finally:
            for ws, sub in ((ws_a, user_sub), (ws_b, user_b_sub)):
                with contextlib.suppress(grpc.RpcError):
                    admin_stub.RemoveWorkspaceMember(
                        openshell_pb2.RemoveWorkspaceMemberRequest(
                            workspace_scope=datamodel_pb2.WorkspaceSelector(
                                workspace=ws
                            ),
                            principal_subject=sub,
                        ),
                        metadata=admin_md,
                    )
