#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Redact credentials and OIDC tokens before retaining a test artifact."""

from __future__ import annotations

import os
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

REDACTED = "[REDACTED]"


def redact_text(text: str, known_secrets: tuple[str, ...] = ()) -> str:
    """Redact credentials and token-shaped fields in plain text."""
    for secret in known_secrets:
        text = text.replace(secret, REDACTED)
    patterns = (
        (r"(?i)(authorization:\s*bearer\s+)[^\s\"'<>]+", r"\1" + REDACTED),
        (r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1" + REDACTED),
        (
            r"(?ix)([\"']?(?:access[_-]?token|id[_-]?token|refresh[_-]?token|client[_-]?secret|password)[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s,}\]<>]+)",
            r"\1" + REDACTED,
        ),
        (r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", "[REDACTED_EMAIL]"),
    )
    for pattern, replacement in patterns:
        text = re.sub(pattern, replacement, text)
    return text


def redact_xml(text: str, known_secrets: tuple[str, ...] = ()) -> str:
    """Redact XML attributes and text without consuming XML markup."""
    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        raise ValueError(f"cannot parse JUnit XML for redaction: {exc}") from exc

    for element in root.iter():
        element.attrib.update(
            {
                name: redact_text(value, known_secrets)
                for name, value in element.attrib.items()
            }
        )
        if element.text:
            element.text = redact_text(element.text, known_secrets)
        if element.tail:
            element.tail = redact_text(element.tail, known_secrets)
    return ET.tostring(root, encoding="unicode")


def main() -> None:
    """Redact known fixture credentials and generic token-shaped log fields."""
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: redact-oidc-artifact.py SOURCE DEST [--xml]")
    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    text = source.read_text(errors="replace")

    secret_names = (
        "OIDC_REDACT_DB_PASSWORD",
        "OIDC_REDACT_ADMIN_PASSWORD",
        "OIDC_REDACT_USER_PASSWORD",
        "OIDC_REDACT_USER_B_PASSWORD",
        "OIDC_REDACT_CLIENT_SECRET",
    )
    known_secrets = tuple(
        value for name in secret_names if (value := os.environ.get(name, ""))
    )

    if len(sys.argv) == 4:
        if sys.argv[3] != "--xml":
            raise SystemExit("usage: redact-oidc-artifact.py SOURCE DEST [--xml]")
        # Parse first so XML entities such as &amp; are decoded before known
        # secret replacement; replacing the raw markup can miss the secret.
        text = redact_xml(text, known_secrets)
    else:
        text = redact_text(text, known_secrets)
    destination.write_text(text)


if __name__ == "__main__":
    main()
