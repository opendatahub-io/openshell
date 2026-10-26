#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Record archive identity and configure relocatable nextest reports."""

import argparse
import hashlib
import json
import pathlib
import re
import sys
import tomllib


def archive_metadata(archive, suite, features):
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {
        "schema": 1,
        "suite": suite,
        "features": sorted(set(filter(None, features.split(",")))),
        "sha256": digest,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("write", "validate"):
        sub = commands.add_parser(command)
        sub.add_argument("archive", type=pathlib.Path)
        sub.add_argument("suite", choices=("kubernetes", "conformance"))
        sub.add_argument("features", nargs="?", default="")
    config = commands.add_parser("config")
    config.add_argument("source", type=pathlib.Path)
    config.add_argument("destination", type=pathlib.Path)
    config.add_argument("report", type=pathlib.Path)
    config.add_argument("conformance_report", type=pathlib.Path)
    args = parser.parse_args()
    if args.command == "config":
        # Start with the current upstream profiles, retaining their filters,
        # overrides and test groups. Only report placement is image-specific.
        source = args.source.read_text(encoding="utf-8")
        expected = tomllib.loads(source)
        profiles = expected.get("profile", {})
        if "odh-image-conformance" in profiles:
            raise ValueError("odh-image-conformance profile already exists")

        # Anchor on the table, allowing indentation, comments, blank lines and
        # reordered fields. Parse before and after so unsupported layouts fail
        # closed instead of silently altering unrelated profiles.
        def key(value):
            return (
                rf"(?:{re.escape(value)}|\"{re.escape(value)}\"|'{re.escape(value)}')"
            )

        header = (
            rf"(?m)^[ \t]*\[[ \t]*{key('profile')}[ \t]*\."
            rf"[ \t]*{key('e2e-kubernetes')}[ \t]*\."
            rf"[ \t]*{key('junit')}[ \t]*\][ \t]*(?:#[^\n]*)?$"
        )
        match = re.search(header, source)
        if match is None:
            raise ValueError("missing e2e-kubernetes JUnit table")
        following = re.search(r"(?m)^[ \t]*\[", source[match.end() :])
        end = match.end() + following.start() if following else len(source)
        body, count = re.subn(
            r"(?m)^[ \t]*(?:path|\"path\"|'path')[ \t]*=[^\n]*$",
            lambda _: (
                "path = " + json.dumps(str(args.report.resolve()), ensure_ascii=False)
            ),
            source[match.end() : end],
        )
        if count != 1:
            raise ValueError("expected one JUnit path for profile e2e-kubernetes")
        text = source[: match.end()] + body + source[end:]
        conformance_report = args.conformance_report.resolve()
        # These tests start servers on the runner, which remote sandboxes cannot
        # reach through host.openshell.internal.
        conformance_filter = "not test(/^credential_gating::/)"
        text += (
            "\n[profile.odh-image-conformance]\n"
            f"default-filter = {json.dumps(conformance_filter)}\n"
            "fail-fast = false\n"
            'status-level = "slow"\n'
            'final-status-level = "fail"\n'
            'failure-output = "immediate-final"\n'
            "\n[profile.odh-image-conformance.junit]\n"
            f"path = {json.dumps(str(conformance_report), ensure_ascii=False)}\n"
        )
        profiles["e2e-kubernetes"]["junit"]["path"] = str(args.report.resolve())
        profiles["odh-image-conformance"] = {
            "default-filter": conformance_filter,
            "fail-fast": False,
            "status-level": "slow",
            "final-status-level": "fail",
            "failure-output": "immediate-final",
            "junit": {"path": str(conformance_report)},
        }
        if tomllib.loads(text) != expected:
            raise ValueError("report configuration changed unrelated nextest settings")
        args.destination.write_text(text, encoding="utf-8")
        return
    expected = archive_metadata(args.archive, args.suite, args.features)
    metadata_path = pathlib.Path(str(args.archive) + ".json")
    if args.command == "write":
        metadata_path.write_text(json.dumps(expected, indent=2) + "\n")
    elif json.loads(metadata_path.read_text()) != expected:
        raise ValueError(
            f"archive suite, features, or checksum mismatch: {args.archive}"
        )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(2)
