# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Exercise packaged runner dispatch without a cluster or compiled test suite."""

import contextlib
import hashlib
import json
import os
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class ArchiveRunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in (
            "odh/scripts/kubernetes-image.sh",
            "odh/scripts/test-archive.py",
            "odh/scripts/e2e-odh-entrypoint.sh",
            "odh/scripts/python-e2e-common.sh",
            "e2e/support/child-process.sh",
            "e2e/support/run-child.py",
            "e2e/support/reports.sh",
            "scripts/junit-to-html.xsl",
            ".config/nextest.toml",
        ):
            dest = self.root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, dest)
        (self.root / "tests/suites/conformance").mkdir(parents=True)
        (self.root / "e2e/rust").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.jsonl"
        self.program(
            "cargo",
            f"#!{sys.executable}\n"
            + """
import json, os, pathlib, signal, sys, time, tomllib
args = sys.argv[1:]
if "OPENSHELL_GATEWAY_ENDPOINT" in os.environ:
    sys.exit("stale gateway endpoint reached cargo")
with open(os.environ["COMMAND_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
config = pathlib.Path(args[args.index("--config-file") + 1])
settings = tomllib.loads(config.read_text())
pathlib.Path(os.environ["COMMAND_LOG"] + ".config").write_text(json.dumps(settings))
if args[:2] == ["nextest", "run"]:
    profile = args[args.index("--profile") + 1]
    if os.environ.get("WAIT_FOR_SIGNAL") == profile:
        def stop(*_):
            pathlib.Path(os.environ["COMMAND_LOG"] + ".stopped").touch()
            sys.exit(143)
        signal.signal(signal.SIGTERM, stop)
        pathlib.Path(os.environ["COMMAND_LOG"] + ".ready").touch()
        while True:
            time.sleep(0.05)
    report = pathlib.Path(settings["profile"][profile]["junit"]["path"])
    if not os.environ.get("MISSING_REPORT"):
        report.write_text('<testsuites tests="1" failures="0"/>')
    status = os.environ.get("TEST_STATUS", "0")
    if profile == "e2e-kubernetes":
        status = os.environ.get("KUBERNETES_STATUS", status)
    sys.exit(int(status))
""",
        )
        wrapper = self.root / "e2e/with-kube-gateway.sh"
        wrapper.write_text(
            "#!/usr/bin/env bash\n"
            "[[ ! -v OPENSHELL_GATEWAY_ENDPOINT ]] || exit 91\n"
            'touch "${COMMAND_LOG}.deployed"\nexec "$@"\n'
        )
        wrapper.chmod(0o755)
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith(("OPENSHELL_", "KATA_")):
                del self.env[key]
        self.env.update(
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            PYTHON_BIN=sys.executable,
            COMMAND_LOG=str(self.log),
            OPENSHELL_BIN="/bin/true",
            KUBECONFIG=str(self.root / "kubeconfig"),
            OPENSHELL_E2E_KUBE_CONTEXT="fixture-context",
            OPENSHELL_E2E_RESULTS_DIR=str(self.root / "reports"),
            OPENSHELL_E2E_KUBERNETES_ARCHIVE=str(
                self.archive("kubernetes", "e2e,e2e-kubernetes")
            ),
            OPENSHELL_E2E_CONFORMANCE_ARCHIVE=str(self.archive("conformance", "")),
        )
        self.entrypoint = self.root / "odh/scripts/e2e-odh-entrypoint.sh"

    def test_stale_endpoint_is_cleared_before_deployment_and_tests(self):
        result = self.run_image(OPENSHELL_GATEWAY_ENDPOINT="https://stale.example")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(Path(str(self.log) + ".deployed").exists())

    def test_direct_runner_also_clears_stale_endpoint(self):
        result = subprocess.run(
            ["bash", str(self.root / "odh/scripts/kubernetes-image.sh")],
            env=self.env | {"OPENSHELL_GATEWAY_ENDPOINT": "https://stale.example"},
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_non_bmp_report_path(self):
        reports = self.root / "reports-\U0001f680"
        result = self.run_image(OPENSHELL_E2E_RESULTS_DIR=str(reports))
        self.assertEqual(result.returncode, 0, result.stderr)
        for suffix in ("", "-conformance"):
            self.assertTrue((reports / f"e2e-kubernetes{suffix}.xml").is_file())

    def test_junit_table_accepts_reformatting_and_preserves_other_settings(self):
        config = self.root / ".config/nextest.toml"
        config.write_text(
            config.read_text().replace(
                "[profile.e2e-kubernetes.junit]\npath = ",
                '  [ profile . "e2e-kubernetes" . junit ] # report\n'
                '\n# keep this table\nstore-success-output = true\n  "path"\t=\t',
            )
        )
        self.test_configuration_keeps_upstream_filters_and_overrides()

    def test_explicit_conformance_report_path_is_used(self):
        destination = self.root / "generated.toml"
        report = self.root / "reports/independent-conformance-name.xml"
        result = subprocess.run(
            [
                sys.executable,
                str(self.root / "odh/scripts/test-archive.py"),
                "config",
                str(self.root / ".config/nextest.toml"),
                str(destination),
                str(self.root / "reports/main.xml"),
                str(report),
            ],
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        config = tomllib.loads(destination.read_text())
        self.assertEqual(
            config["profile"]["odh-image-conformance"]["junit"]["path"], str(report)
        )

    def test_configuration_keeps_upstream_filters_and_overrides(self):
        result = self.run_image()
        self.assertEqual(result.returncode, 0, result.stderr)
        generated = json.loads(Path(str(self.log) + ".config").read_text())
        upstream = tomllib.loads((self.root / ".config/nextest.toml").read_text())
        self.assertEqual(
            generated["profile"].pop("odh-image-conformance")["junit"]["path"],
            str(self.root / "reports/e2e-kubernetes-conformance.xml"),
        )
        generated["profile"]["e2e-kubernetes"]["junit"]["path"] = upstream["profile"][
            "e2e-kubernetes"
        ]["junit"]["path"]
        self.assertEqual(generated, upstream)

    def program(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def archive(self, suite, features):
        path = self.root / (suite + ".tar.zst")
        path.write_bytes(b"fixture archive")
        Path(str(path) + ".json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "suite": suite,
                    "features": sorted(filter(None, features.split(","))),
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                }
            )
        )
        return path

    def run_image(self, **overrides):
        return subprocess.run(
            ["bash", str(self.entrypoint), "kubernetes"],
            env=self.env | overrides,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_dispatch_runs_both_archives_without_build_arguments(self):
        result = self.run_image(OPENSHELL_E2E_KUBE_TEST="sandbox_lifecycle")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual(
            [c[:2] for c in commands],
            [["nextest", "run"]] * 2,
        )
        self.assertTrue(
            all("--features" not in c and "--manifest-path" not in c for c in commands)
        )
        self.assertIn("binary(=sandbox_lifecycle)", commands[-1])
        self.assertIn("--test-threads", commands[-2])
        self.assertTrue((self.root / "reports/e2e-kubernetes.xml").is_file())
        self.assertTrue(
            (self.root / "reports/e2e-kubernetes-conformance.xml").is_file()
        )

    def test_feature_order_is_normalized(self):
        result = self.run_image(OPENSHELL_E2E_KUBERNETES_FEATURES="e2e-kubernetes,e2e")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_mismatched_features_fail_before_deploy_and_remove_stale_reports(self):
        reports = self.root / "reports"
        reports.mkdir()
        stale = reports / "e2e-kubernetes.xml"
        stale.write_text("old result")
        result = self.run_image(
            OPENSHELL_E2E_KUBERNETES_FEATURES="e2e,e2e-host-gateway,e2e-kubernetes"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mismatch", result.stderr)
        self.assertFalse(Path(str(self.log) + ".deployed").exists())
        self.assertFalse(stale.exists())

    def test_corrupt_or_missing_archives_fail_before_deploy(self):
        for missing in (False, True):
            with self.subTest(missing=missing):
                archive = self.archive("kubernetes", "e2e,e2e-kubernetes")
                if missing:
                    archive.unlink()
                else:
                    archive.write_bytes(b"wrong binary")
                result = self.run_image()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(Path(str(self.log) + ".deployed").exists())

    def test_component_build_request_is_rejected(self):
        result = self.run_image(OPENSHELL_E2E_KUBE_BUILD_IMAGES="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_conformance_failure_prevents_rust_suite_and_preserves_status(self):
        result = self.run_image(TEST_STATUS="17")
        self.assertEqual(result.returncode, 17, result.stderr)
        runs = [c for c in self.commands() if c[:2] == ["nextest", "run"]]
        self.assertEqual(len(runs), 1)
        self.assertFalse((self.root / "reports/e2e-kubernetes.xml").exists())

    def test_success_without_report_is_failure(self):
        result = self.run_image(MISSING_REPORT="1")
        self.assertNotEqual(result.returncode, 0)

    def test_kubernetes_failure_preserves_status_and_both_reports(self):
        result = self.run_image(KUBERNETES_STATUS="100")
        self.assertEqual(result.returncode, 100, result.stderr)
        self.assertTrue((self.root / "reports/e2e-kubernetes.xml").is_file())
        self.assertTrue(
            (self.root / "reports/e2e-kubernetes-conformance.xml").is_file()
        )

    def test_artifact_check_needs_no_cluster_and_does_not_run_tests(self):
        self.program("curl", '#!/usr/bin/env bash\nprintf "Features: HTTP2 SSL\\n"\n')
        env = self.env.copy()
        env.pop("KUBECONFIG")
        env.pop("OPENSHELL_E2E_KUBE_CONTEXT")
        result = subprocess.run(
            ["bash", str(self.root / "odh/scripts/kubernetes-image.sh"), "--check"],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[:2] for c in self.commands()], [["nextest", "list"]] * 2)
        self.assertFalse(Path(str(self.log) + ".deployed").exists())

    def test_sigterm_reaches_the_test_process(self):
        for profile in ("odh-image-conformance", "e2e-kubernetes"):
            with self.subTest(profile=profile):
                self.check_sigterm(profile)

    def check_sigterm(self, profile):
        for suffix in (".ready", ".stopped"):
            Path(str(self.log) + suffix).unlink(missing_ok=True)
        with tempfile.TemporaryFile() as output:
            process = subprocess.Popen(
                ["bash", str(self.entrypoint), "kubernetes"],
                env=self.env | {"WAIT_FOR_SIGNAL": profile},
                stdout=output,
                stderr=output,
                start_new_session=True,
            )
            try:
                ready = Path(str(self.log) + ".ready")
                deadline = time.monotonic() + 10
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=5), 143)
                self.assertTrue(Path(str(self.log) + ".stopped").exists())
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()


class ProcessGroupTests(unittest.TestCase):
    def test_background_child_preserves_stdin(self):
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; e2e_run_child cat',
                "bash",
                str(ROOT / "e2e/support/child-process.sh"),
            ],
            env=dict(os.environ, PYTHON_BIN=sys.executable),
            input="input for the test process\n",
            text=True,
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "input for the test process\n")

    @unittest.skipUnless(sys.platform == "linux", "checks process state through procfs")
    def test_termination_kills_uncooperative_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "pids.json"
            ready = Path(directory) / "ready"
            descendant = (
                "import pathlib,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                f"pathlib.Path({str(ready)!r}).touch(); time.sleep(60)"
            )
            command = (
                "import json,os,pathlib,signal,subprocess,sys,time\n"
                "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                f"child=subprocess.Popen([sys.executable,'-c',{descendant!r}])\n"
                f"while not pathlib.Path({str(ready)!r}).exists(): time.sleep(0.01)\n"
                f"pathlib.Path({str(pid_file)!r}).write_text(json.dumps([os.getpid(),child.pid]))\n"
                "child.wait()\n"
            )
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(ROOT / "e2e/support/run-child.py"),
                    "--grace",
                    "0.2",
                    "--",
                    sys.executable,
                    "-c",
                    command,
                ],
                start_new_session=True,
            )
            pids = []
            try:
                deadline = time.monotonic() + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(pid_file.exists(), "descendant did not start")
                pids = json.loads(pid_file.read_text())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=3), 143)
                for pid in pids:
                    try:
                        state = (
                            Path(f"/proc/{pid}/stat")
                            .read_text()
                            .split(") ", 1)[1]
                            .split()[0]
                        )
                    except FileNotFoundError:
                        continue
                    self.assertEqual(state, "Z", f"process {pid} survived cancellation")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                for pid in pids:
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(pid, signal.SIGKILL)


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
