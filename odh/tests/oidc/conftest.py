# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Fork-only OIDC test fixtures for the ODH lane.

This directory holds downstream workspace-authorization coverage that must
not drift the upstream-shared ``e2e/python/oidc`` suite. The ODH OIDC runner
(``odh/scripts/run-python-e2e.sh --oidc``) collects this directory
alongside ``e2e/python/oidc`` in the same pytest invocation, so both run
against the same per-run Keycloak fixture and gateway.

There is deliberately no ``__init__.py`` here: the upstream
``e2e/python/oidc`` package already owns the ``oidc`` module name in this
pytest run, so these tests resolve to flat, collision-free module names.
"""

from __future__ import annotations

import sys
from pathlib import Path

from oidc_credentials_plugin import install_oidc_credential_overrides

# Reuse the upstream OIDC helpers (token acquisition, gRPC channel, JWT
# decoding) without modifying any upstream file: put the upstream OIDC
# directory on sys.path so the fork-only tests can import its helpers
# module directly.
_UPSTREAM_OIDC_DIR = Path(__file__).resolve().parents[3] / "e2e" / "python" / "oidc"
if str(_UPSTREAM_OIDC_DIR) not in sys.path:
    sys.path.insert(0, str(_UPSTREAM_OIDC_DIR))


install_oidc_credential_overrides()
