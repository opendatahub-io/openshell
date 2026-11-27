# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Shared helpers for downstream ODH OIDC tests.

Centralizes duplicated JWT/workspace helpers that appeared in each new
downstream module. Reuses upstream ``e2e/python/oidc/helpers.py`` for token
acquisition — this module only adds small downstream conveniences.
"""

from __future__ import annotations

import base64
import json
from typing import Any


def decode_claims(token: str) -> dict[str, Any]:
    """Decode JWT payload without verification (for claim assertions only)."""
    payload = token.split(".")[1]
    padded = payload + "=" * (4 - len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(padded))


def audience_contains(claims: dict[str, Any], audience: str) -> bool:
    """Return True if ``audience`` is present in the ``aud`` claim."""
    aud = claims.get("aud")
    if isinstance(aud, str):
        return audience in aud.split()
    if isinstance(aud, list):
        return audience in aud
    return False
