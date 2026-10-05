# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Redact credentials and OIDC tokens before retaining a test artifact."""

from __future__ import annotations

import os
import pathlib
import re
import sys


def main() -> None:
    """Redact known fixture credentials and generic token-shaped log fields."""
    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    text = source.read_text(errors="replace")

    for name in (
        "OIDC_REDACT_DB_PASSWORD",
        "OIDC_REDACT_ADMIN_PASSWORD",
        "OIDC_REDACT_USER_PASSWORD",
        "OIDC_REDACT_USER_B_PASSWORD",
        "OIDC_REDACT_CLIENT_SECRET",
    ):
        value = os.environ.get(name, "")
        if value:
            text = text.replace(value, "[REDACTED]")

    # Diagnostic output can contain OIDC request headers or JSON payloads in
    # addition to this run's generated fixture credentials. The key/value
    # pattern intentionally accepts quoted JSON keys and values as well as
    # conventional log entries such as access_token=... .
    patterns = (
        (r"(?i)(authorization:\s*bearer\s+)[^\s\"']+", r"\1[REDACTED]"),
        (r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1[REDACTED]"),
        (
            r"(?ix)([\"']?(?:access[_-]?token|id[_-]?token|refresh[_-]?token|client[_-]?secret|password)[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s,}\]]+)",
            r"\1[REDACTED]",
        ),
        (r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", "[REDACTED_EMAIL]"),
    )
    for pattern, replacement in patterns:
        text = re.sub(pattern, replacement, text)
    destination.write_text(text)


if __name__ == "__main__":
    main()
