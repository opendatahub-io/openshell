#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Resolve unset e2e runtime images from the installed RHOAI or ODH CSV."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

IMAGE_ENV = {
    "GATEWAY_IMAGE": "RELATED_IMAGE_ODH_OPENSHELL_GATEWAY_IMAGE",
    "SANDBOX_IMAGE": "RELATED_IMAGE_ODH_OPENSHELL_SANDBOX_IMAGE",
    "SUPERVISOR_IMAGE": "RELATED_IMAGE_ODH_OPENSHELL_SUPERVISOR_IMAGE",
}
PRODUCTS = {"rhods-operator.": "RHOAI", "opendatahub-operator.": "ODH"}
CSV_RESOURCE = "clusterserviceversions.operators.coreos.com"


def oc(*args: str) -> str:
    result = subprocess.run(["oc", *args], capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(f"oc {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def discover() -> dict[str, str]:
    needed = {key: value for key, value in IMAGE_ENV.items() if not os.environ.get(key)}
    if not needed:
        print(
            ">> All runtime images explicitly set; skipping CSV discovery",
            file=sys.stderr,
        )
        return {}

    resources = oc("api-resources", "--api-group=operators.coreos.com", "-o", "name")
    if CSV_RESOURCE not in resources.split():
        print(
            ">> OLM CSV API absent; using explicit images and existing defaults",
            file=sys.stderr,
        )
        return {}

    csvs = json.loads(oc("get", CSV_RESOURCE, "--all-namespaces", "-o", "json"))
    candidates = []
    for csv in csvs["items"]:
        metadata = csv.get("metadata", {})
        status = csv.get("status", {})
        if (
            "olm.copiedFrom" in metadata.get("labels", {})
            or status.get("reason") == "Copied"
        ):
            continue
        name = metadata.get("name", "")
        for prefix, product in PRODUCTS.items():
            if name.startswith(prefix):
                candidates.append((product, csv))
                break

    if not candidates:
        print(
            ">> No RHOAI or ODH operator CSV installed; using explicit images and existing defaults",
            file=sys.stderr,
        )
        return {}

    installed = [
        (product, csv)
        for product, csv in candidates
        if csv.get("status", {}).get("phase") == "Succeeded"
    ]
    if len(installed) != 1:
        names = ", ".join(
            f"{csv['metadata'].get('namespace', '')}/{csv['metadata']['name']}"
            f" ({csv.get('status', {}).get('phase', 'unknown')})"
            for _, csv in candidates
        )
        raise ValueError(
            f"expected one Succeeded RHOAI/ODH operator CSV, found {len(installed)}: {names}. "
            "Set GATEWAY_IMAGE, SANDBOX_IMAGE, and SUPERVISOR_IMAGE to bypass discovery"
        )

    product, csv = installed[0]
    source = f"{csv['metadata']['namespace']}/{csv['metadata']['name']}"
    print(f">> Detected {product} operator CSV {source}", file=sys.stderr)
    values: dict[str, set[str]] = {name: set() for name in needed.values()}
    for deployment in (
        csv.get("spec", {}).get("install", {}).get("spec", {}).get("deployments", [])
    ):
        containers = (
            deployment.get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("containers", [])
        )
        for container in containers:
            for env in container.get("env", []):
                if env.get("name") in values:
                    values[env["name"]].add(env.get("value", ""))

    images = {}
    for override, related in needed.items():
        found = values[related]
        if len(found) != 1:
            raise ValueError(
                f"CSV {source} has missing or conflicting {related}; set {override} explicitly"
            )
        image = next(iter(found))
        if not re.fullmatch(r"[^\s@]+/[^\s@]+@sha256:[0-9a-f]{64}", image):
            raise ValueError(
                f"CSV {source} {related} must be a full sha256-pinned image reference; "
                f"set {override} explicitly"
            )
        images[override] = image
    return images


def main() -> int:
    try:
        images = discover()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"ERROR: e2e image discovery failed: {error}", file=sys.stderr)
        return 1
    # Data only: the entrypoint reads these fields without evaluating shell code.
    for key, image in images.items():
        print(f"{key}\t{image}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
