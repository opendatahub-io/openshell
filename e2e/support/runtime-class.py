#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Construct an isolated E2E RuntimeClass from an administrator's template."""

import argparse
import json
import sys


def runtime_class(template, name):
    # RuntimeClass fields are top-level, not inside spec. In particular, Kata
    # scheduling and overhead are required; metadata/finalizers are not copied.
    result = {
        "apiVersion": "node.k8s.io/v1",
        "kind": "RuntimeClass",
        "metadata": {
            "name": name,
            "labels": {"openshell.ai/sandbox-attachable": "true"},
            "annotations": {
                "openshell.ai/e2e-runtimeclass-source": template["metadata"]["name"]
            },
        },
        "handler": template["handler"],
    }
    for field in ("overhead", "scheduling"):
        if field in template:
            result[field] = template[field]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name")
    args = parser.parse_args()
    json.dump(runtime_class(json.load(sys.stdin), args.name), sys.stdout)
    print()
