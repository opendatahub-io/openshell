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
    args = parser.parse_args()
    if args.command == "config":
        # Start with the current upstream profiles, retaining their filters,
        # overrides and test groups. Only report placement is image-specific.
        source = args.source.read_text()
        profiles = tomllib.loads(source).get("profile", {})
        if "odh-image-conformance" in profiles:
            raise ValueError("odh-image-conformance profile already exists")
        pattern = r"(\[profile\.e2e-kubernetes\.junit\]\s*\n)path = [^\n]+"
        text, count = re.subn(
            pattern,
            lambda match: match[1] + "path = " + json.dumps(str(args.report.resolve())),
            source,
        )
        if count != 1:
            raise ValueError("expected one JUnit path for profile e2e-kubernetes")
        conformance_report = args.report.with_name(
            args.report.stem + "-conformance.xml"
        ).resolve()
        text += (
            "\n[profile.odh-image-conformance]\n"
            "fail-fast = false\n"
            'status-level = "slow"\n'
            'final-status-level = "fail"\n'
            'failure-output = "immediate-final"\n'
            "\n[profile.odh-image-conformance.junit]\n"
            f"path = {json.dumps(str(conformance_report))}\n"
        )
        tomllib.loads(text)
        args.destination.write_text(text)
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
