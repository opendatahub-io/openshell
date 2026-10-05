# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Session-lifecycle checks specific to the ephemeral OCP Keycloak realm."""

from __future__ import annotations

import os
import time
import urllib.error

import grpc
import pytest

from odh.tests.oidc.helpers import (
    extract_jwt_claims,
    extract_sub,
    get_token_response,
    refresh_token,
    stub_with_token,
)
from openshell._proto import datamodel_pb2, openshell_pb2

pytestmark = pytest.mark.skipif(
    os.environ.get("OPENSHELL_E2E_OIDC_SESSION_LIFECYCLE") != "1",
    reason="OIDC session lifecycle tests are enabled by the OpenShift runner",
)


def _list_sandboxes(token: str) -> None:
    stub, metadata = stub_with_token(token)
    stub.ListSandboxes(
        openshell_pb2.ListSandboxesRequest(
            workspace_scope=datamodel_pb2.WorkspaceSelector(workspace="default")
        ),
        metadata=metadata,
    )


class TestSessionLifecycle:
    """Verify refresh and expiry behavior against the deployed OIDC gateway."""

    def test_refresh_token_produces_an_authorized_access_token(self) -> None:
        initial = get_token_response("admin@test", scopes="openid openshell:all")
        refreshed = refresh_token(str(initial["refresh_token"]))
        refreshed_access_token = str(refreshed["access_token"])

        assert extract_sub(refreshed_access_token) == extract_sub(
            str(initial["access_token"])
        )
        _list_sandboxes(refreshed_access_token)

    def test_invalid_refresh_token_is_rejected(self) -> None:
        with pytest.raises(urllib.error.HTTPError) as exc_info:
            refresh_token("not-a-valid-refresh-token")
        assert exc_info.value.code == 400

    def test_expired_access_token_is_rejected_by_gateway(self) -> None:
        response = get_token_response("admin@test", scopes="openid openshell:all")
        access_token = str(response["access_token"])
        expires_at = int(extract_jwt_claims(access_token)["exp"])
        issuance_delay = expires_at - time.time()

        assert 0 < issuance_delay <= 30, (
            "OIDC fixture did not issue a short-lived token"
        )

        # jsonwebtoken accepts expiration times within its 60-second default
        # clock-skew leeway. Wait beyond that window so this verifies the
        # gateway's actual expiration rejection rather than a race at `exp`.
        time.sleep(max(0, expires_at - time.time() + 62))

        with pytest.raises(grpc.RpcError) as exc_info:
            _list_sandboxes(access_token)
        assert exc_info.value.code() == grpc.StatusCode.UNAUTHENTICATED

    def test_refresh_token_after_client_session_expiry_is_rejected(self) -> None:
        response = get_token_response("admin@test", scopes="openid openshell:all")
        refresh_lifetime = int(response["refresh_expires_in"])

        assert 0 < refresh_lifetime <= 30, (
            "OIDC fixture did not issue a short-lived refresh token"
        )
        time.sleep(refresh_lifetime + 1)

        with pytest.raises(urllib.error.HTTPError) as exc_info:
            refresh_token(str(response["refresh_token"]))
        assert exc_info.value.code == 400
