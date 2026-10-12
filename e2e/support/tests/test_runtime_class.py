# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Check preservation of Kata configuration in a per-run RuntimeClass."""

import runpy
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class RuntimeClassTests(unittest.TestCase):
    def test_copy_preserves_runtime_configuration_without_admin_metadata(self):
        build = runpy.run_path(str(ROOT / "e2e/support/runtime-class.py"))[
            "runtime_class"
        ]
        source = {
            "metadata": {
                "name": "kata",
                "uid": "admin-owned",
                "finalizers": ["operator"],
                "labels": {"openshell.ai/sandbox-attachable": "false"},
            },
            "handler": "kata",
            "overhead": {"podFixed": {"memory": "350Mi"}},
            "scheduling": {"nodeSelector": {"kata-node": "true"}, "tolerations": []},
        }
        copy = build(source, "openshell-e2e-example")
        for field in ("handler", "overhead", "scheduling"):
            self.assertEqual(copy[field], source[field])
        self.assertEqual(copy["metadata"]["name"], "openshell-e2e-example")
        self.assertEqual(
            copy["metadata"]["labels"]["openshell.ai/sandbox-attachable"], "true"
        )
        self.assertNotIn("uid", copy["metadata"])
        self.assertNotIn("finalizers", copy["metadata"])
        self.assertEqual(
            source["metadata"]["labels"]["openshell.ai/sandbox-attachable"], "false"
        )


if __name__ == "__main__":
    unittest.main()
