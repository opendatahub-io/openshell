# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Inject per-run OIDC fixture credentials into upstream and fork tests."""

from __future__ import annotations

import contextlib
import importlib
import os
import sys
from pathlib import Path
from typing import Any

import openshell

_ROOT = Path(__file__).resolve().parents[3]
for _path in (_ROOT / "e2e" / "python", _ROOT / "e2e" / "python" / "oidc"):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

_INSTALLED = False


def _patch_oidc_helper(module: Any) -> None:
    original_get_token = module.get_token
    original_get_ci_token = module.get_ci_token
    passwords = {
        "admin@test": os.environ["OPENSHELL_E2E_OIDC_ADMIN_PASSWORD"],
        "user@test": os.environ["OPENSHELL_E2E_OIDC_USER_PASSWORD"],
        "user-b@test": os.environ["OPENSHELL_E2E_OIDC_USER_B_PASSWORD"],
        "revocation@test": os.environ.get(
            "OPENSHELL_E2E_OIDC_REVOCATION_USER_PASSWORD", ""
        ),
    }

    def get_token(username: str, _password: str, **kwargs: object) -> str:
        return original_get_token(username, passwords[username], **kwargs)

    def get_ci_token(**kwargs: object) -> str:
        if "client_secret" not in kwargs:
            if kwargs.get("client_id") == "openshell-revocation-test":
                rev_secret = os.environ.get(
                    "OPENSHELL_E2E_OIDC_REVOCATION_CLIENT_SECRET"
                )
                if rev_secret:
                    kwargs["client_secret"] = rev_secret
                    return original_get_ci_token(**kwargs)
            kwargs["client_secret"] = os.environ["OPENSHELL_E2E_OIDC_CI_CLIENT_SECRET"]
        return original_get_ci_token(**kwargs)

    module.get_token = get_token  # type: ignore[attr-defined]
    module.get_ci_token = get_ci_token  # type: ignore[attr-defined]


def install_oidc_credential_overrides() -> None:
    """Patch every OIDC helper module before pytest imports test modules."""
    global _INSTALLED
    if _INSTALLED:
        return
    required_credentials = (
        "OPENSHELL_E2E_OIDC_ADMIN_PASSWORD",
        "OPENSHELL_E2E_OIDC_USER_PASSWORD",
        "OPENSHELL_E2E_OIDC_USER_B_PASSWORD",
        "OPENSHELL_E2E_OIDC_CI_CLIENT_SECRET",
    )
    if any(name not in os.environ for name in required_credentials):
        return
    for module_name in ("helpers", "oidc.helpers"):
        with contextlib.suppress(ModuleNotFoundError):
            _patch_oidc_helper(importlib.import_module(module_name))

    original_client_credentials_auth = openshell.ClientCredentialsAuth

    def client_credentials_auth(*args: Any, **kwargs: Any) -> Any:
        """Replace the upstream test's published fallback secret per run."""
        if kwargs.get("client_id") == "openshell-ci":
            kwargs["client_secret"] = os.environ["OPENSHELL_E2E_OIDC_CI_CLIENT_SECRET"]
        return original_client_credentials_auth(*args, **kwargs)

    openshell.ClientCredentialsAuth = client_credentials_auth  # type: ignore[assignment]
    _INSTALLED = True


def pytest_configure(config: Any) -> None:
    del config
    install_oidc_credential_overrides()
