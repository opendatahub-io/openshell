# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""CSV selection and local/image entrypoint contracts; no cluster required."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "odh/scripts"
spec = importlib.util.spec_from_file_location(
    "discover_e2e_images", SCRIPTS / "discover-e2e-images.py"
)
discovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discovery)
IMAGES = {
    key: f"registry.redhat.io/rhoai/{key.lower()}@sha256:{digit * 64}"
    for digit, key in zip("123", discovery.IMAGE_ENV, strict=True)
}


def operator(name="rhods-operator.3.6.0", phase="Succeeded", **metadata):
    return {
        "metadata": {"name": name, "namespace": "operator-ns", **metadata},
        "status": {"phase": phase},
        "spec": {
            "install": {
                "spec": {
                    "deployments": [
                        {
                            "spec": {
                                "template": {
                                    "spec": {
                                        "containers": [
                                            {
                                                "env": [
                                                    {
                                                        "name": discovery.IMAGE_ENV[
                                                            key
                                                        ],
                                                        "value": image,
                                                    }
                                                    for key, image in IMAGES.items()
                                                ]
                                            }
                                        ]
                                    }
                                }
                            }
                        }
                    ]
                }
            }
        },
    }


def env_entries(csv):
    return csv["spec"]["install"]["spec"]["deployments"][0]["spec"]["template"]["spec"][
        "containers"
    ][0]["env"]


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.csvs = [operator()]
        self.api = discovery.CSV_RESOURCE
        self.oc = patch.object(discovery, "oc", side_effect=self.query).start()
        self.addCleanup(patch.stopall)

    def query(self, *args):
        if args[0] == "api-resources":
            return self.api
        self.assertEqual(
            args,
            ("get", discovery.CSV_RESOURCE, "--all-namespaces", "-o", "json"),
        )
        return json.dumps({"items": self.csvs})

    def test_rhoai_and_odh(self):
        for name in ("rhods-operator.3.6.0", "opendatahub-operator.v3.6.0"):
            with self.subTest(name=name):
                self.csvs = [operator(name)]
                self.assertEqual(discovery.discover(), IMAGES)

    def test_no_olm_api(self):
        self.api = "subscriptions.operators.coreos.com"
        self.assertEqual(discovery.discover(), {})
        self.assertEqual(self.oc.call_count, 1)

    def test_unrelated_operators(self):
        self.csvs = [operator("other-operator.1.0")]
        self.assertEqual(discovery.discover(), {})

    def test_no_installed_csvs(self):
        self.csvs = []
        self.assertEqual(discovery.discover(), {})

    def test_copied_and_replacing_csvs_are_ignored(self):
        copied = operator(
            namespace="copied-ns", labels={"olm.copiedFrom": "operator-ns"}
        )
        copied_reason = operator(namespace="another-ns")
        copied_reason["status"]["reason"] = "Copied"
        self.csvs += [
            copied,
            copied_reason,
            operator("rhods-operator.3.5.0", "Replacing"),
        ]
        self.assertEqual(discovery.discover(), IMAGES)

    def test_multiple_installed_csvs_fail(self):
        self.csvs.append(operator("opendatahub-operator.3.6.0"))
        with self.assertRaisesRegex(ValueError, "found 2"):
            discovery.discover()

    def test_no_successful_csv_fails(self):
        self.csvs = [operator(phase="Installing")]
        with self.assertRaisesRegex(ValueError, "found 0"):
            discovery.discover()

    def test_partial_override_does_not_require_that_csv_image(self):
        os.environ["GATEWAY_IMAGE"] = "custom.example/gateway:dev"
        env_entries(self.csvs[0]).pop(0)
        self.assertEqual(
            discovery.discover(),
            {key: image for key, image in IMAGES.items() if key != "GATEWAY_IMAGE"},
        )

    def test_all_overrides_bypass_cluster_queries(self):
        os.environ.update(IMAGES)
        self.assertEqual(discovery.discover(), {})
        self.oc.assert_not_called()

    def test_empty_override_uses_discovery(self):
        os.environ["GATEWAY_IMAGE"] = ""
        self.assertEqual(discovery.discover(), IMAGES)

    def test_identical_repeated_values_are_allowed(self):
        entries = env_entries(self.csvs[0])
        entries.append(deepcopy(entries[0]))
        self.assertEqual(discovery.discover(), IMAGES)

    def test_missing_conflicting_and_unpinned_images_fail(self):
        for invalid in (
            "missing",
            "conflicting",
            "tagged",
            "short-digest",
            "valueFrom",
        ):
            with self.subTest(invalid=invalid):
                self.csvs = [operator()]
                entries = env_entries(self.csvs[0])
                if invalid == "missing":
                    entries.pop(0)
                elif invalid == "conflicting":
                    entries.append({**entries[0], "value": IMAGES["SANDBOX_IMAGE"]})
                elif invalid == "tagged":
                    entries[0]["value"] = "registry.example/gateway:latest"
                elif invalid == "short-digest":
                    entries[0]["value"] = "registry.example/gateway@sha256:123"
                else:
                    entries[0].pop("value")
                    entries[0]["valueFrom"] = {}
                with self.assertRaisesRegex(ValueError, "GATEWAY_IMAGE"):
                    discovery.discover()

    def test_query_errors_fail_closed(self):
        for error in (ValueError("Forbidden"), ValueError("connection refused")):
            self.oc.side_effect = error
            with self.subTest(error=error), self.assertRaises(ValueError):
                discovery.discover()


class EntrypointTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.log = self.work / "calls.jsonl"
        self.fixture = self.work / "csv.json"
        self.fixture.write_text(json.dumps({"items": [operator()]}))
        self.kubeconfig = self.work / "kubeconfig"
        self.kubeconfig.touch()
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.script(
            "oc",
            """
record(['oc', *sys.argv[1:]])
if sys.argv[1] == 'api-resources':
    print('clusterserviceversions.operators.coreos.com routes')
elif sys.argv[1:3] == ['get', 'clusterserviceversions.operators.coreos.com']:
    print(Path(os.environ['CSV_FIXTURE']).read_text())
elif sys.argv[1:3] == ['get', 'namespace']:
    sys.exit(71)  # Stop actual deployment before any cluster mutation.
""",
        )
        self.script(
            "deploy",
            """
record(['deploy', *sys.argv[1:], {key: os.environ.get(key) for key in
    ('GATEWAY_IMAGE', 'SANDBOX_IMAGE', 'SUPERVISOR_IMAGE')}])
if sys.argv[1] == 'deploy':
    Path(os.environ['OPENSHELL_E2E_DEPLOY_STATE_DIR'], 'namespace').touch()
""",
        )
        self.script(
            "phase",
            """
record(['phase', *sys.argv[1:]])
Path(sys.argv[3]).write_text('<testsuite><testcase name="passed"/></testsuite>')
""",
        )
        self.script("openshell", "record(['openshell', *sys.argv[1:]])")
        self.script("helm", "sys.exit('unexpected Helm mutation')")
        self.script("git", "sys.exit('no Git metadata in test image')")
        self.environment = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "CALL_LOG": str(self.log),
            "CSV_FIXTURE": str(self.fixture),
            "KUBECONFIG": str(self.kubeconfig),
            "PYTHON_BIN": sys.executable,
            "OPENSHELL_BIN": str(self.bin / "openshell"),
            "OPENSHELL_E2E_DEPLOY_SCRIPT": str(self.bin / "deploy"),
            "OPENSHELL_E2E_PHASE_RUNNER": str(self.bin / "phase"),
            "OPENSHELL_E2E_RESULTS_DIR": str(self.work / "results"),
            "OPENSHELL_E2E_DEPLOY_GATEWAY": "1",
            "OPENSHELL_E2E_RUN_ID": "discovery-test",
            "ROUTE_HOST": "gateway.example.test",
        }
        for key in (*discovery.IMAGE_ENV, "IMAGE_TAG", "OPENSHELL_E2E_REPORT_MERGER"):
            self.environment.pop(key, None)

    def script(self, name, body):
        path = self.bin / name
        path.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\nfrom pathlib import Path\n"
            "def record(value):\n"
            "    with Path(os.environ['CALL_LOG']).open('a') as stream:\n"
            "        stream.write(json.dumps(value) + '\\n')\n" + body
        )
        path.chmod(0o755)

    def run_script(self, script, *args):
        return subprocess.run(
            ["bash", str(SCRIPTS / script), *args],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_discovered_images_exported_once_across_phases(self):
        self.environment["GATEWAY_IMAGE"] = "custom.example/gateway:override"
        result = self.run_script("e2e-odh-entrypoint.sh", "tier2")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(sum(call[:2] == ["oc", "api-resources"] for call in calls), 1)
        deployments = [call for call in calls if call[:2] == ["deploy", "deploy"]]
        self.assertEqual(len(deployments), 2)
        expected = {**IMAGES, "GATEWAY_IMAGE": "custom.example/gateway:override"}
        for call in deployments:
            self.assertEqual(call[-1], expected)
        self.assertEqual(sum(call[:2] == ["deploy", "teardown"] for call in calls), 2)

    def test_no_deploy_skips_discovery(self):
        self.environment["OPENSHELL_E2E_DEPLOY_GATEWAY"] = "0"
        result = self.run_script("e2e-odh-entrypoint.sh", "smoke")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in self.calls()], ["phase"])

    def test_discovery_error_stops_before_deployment(self):
        self.fixture.write_text(json.dumps({"items": [operator(phase="Failed")]}))
        result = self.run_script("e2e-odh-entrypoint.sh", "smoke")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("image discovery failed", result.stderr)
        self.assertTrue(all(call[0] == "oc" for call in self.calls()))

    def test_all_overrides_work_with_csv_without_openshell_images(self):
        old_csv = operator("rhods-operator.3.5.2")
        env_entries(old_csv).clear()
        self.fixture.write_text(json.dumps({"items": [old_csv]}))
        self.environment.update(IMAGES)
        result = self.run_script("e2e-odh-entrypoint.sh", "smoke")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[0] == "oc" for call in self.calls()))
        deployment = next(
            call for call in self.calls() if call[:2] == ["deploy", "deploy"]
        )
        self.assertEqual(deployment[-1], IMAGES)

    def test_oc_error_reports_error_without_stdout_assignments(self):
        self.script("oc", "print('Forbidden', file=sys.stderr)\nsys.exit(1)")
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "discover-e2e-images.py")],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("Forbidden", result.stderr)

    def test_complete_images_need_no_tag_or_git_metadata(self):
        for images in (IMAGES, {key: f"example.test/{key}:tag" for key in IMAGES}):
            with self.subTest(images=images):
                self.environment.update(images)
                result = self.run_script("openshell-deploy-from-quay.sh", "--yes")
                self.assertEqual(result.returncode, 71, result.stderr)
                for image in images.values():
                    self.assertIn(image, result.stdout)

    def test_bare_repository_still_requires_tag(self):
        self.environment.update(IMAGES)
        self.environment["GATEWAY_IMAGE"] = "example.test/gateway"
        result = self.run_script("openshell-deploy-from-quay.sh", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("IMAGE_TAG is required", result.stderr)

    def test_bare_repository_uses_explicit_tag(self):
        self.environment.update(IMAGES)
        self.environment["GATEWAY_IMAGE"] = "example.test/gateway"
        self.environment["IMAGE_TAG"] = "custom"
        result = self.run_script("openshell-deploy-from-quay.sh", "--yes")
        self.assertEqual(result.returncode, 71, result.stderr)
        self.assertIn("example.test/gateway:custom", result.stdout)


if __name__ == "__main__":
    unittest.main()
