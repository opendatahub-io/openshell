# SPDX-FileCopyrightText: Copyright (c) 2026 OpenShell contributors
# SPDX-License-Identifier: Apache-2.0
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Behavioral tests with a simulated cluster; no network or cluster access."""

import base64
import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "installer", Path(__file__).with_name("install.py")
)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def configuration():
    config = json.loads(Path(__file__).with_name("config.example.json").read_text())
    config["context"] = "test-context"
    config["gateway"]["version"] = "0.1.3"
    config["dashboard"]["version"] = "0.1.7"
    config["oidc"].pop("client_secret_file")
    return config


class FakeCluster(installer.Installer):
    def __init__(self, config):
        super().__init__(config, "10m")
        self.objects = {
            ("crd", "sandboxes.agents.x-k8s.io"): {
                "spec": {"versions": [{"name": "v1beta1", "served": True}]}
            }
        }
        self.calls = []
        self.releases = []
        self.manifests = {}
        self.fail_dashboard = False
        self.storage = [
            {
                "metadata": {
                    "name": "block",
                    "annotations": {
                        "storageclass.kubernetes.io/is-default-class": "true"
                    },
                }
            }
        ]
        self.other_states = []
        self.denied_permission = None

    def run(self, args, payload=None):
        self.calls.append((args, payload))
        if (
            args[0] == "kubectl"
            and "-n" in args
            and "get" in args
            and ("namespace", args[args.index("-n") + 1]) not in self.objects
        ):
            raise RuntimeError("namespace not found")
        if "can-i" in args:
            return (
                "no"
                if self.denied_permission and self.denied_permission in args
                else "yes"
            )
        if "storageclasses" in args:
            return json.dumps({"items": self.storage})
        if "nodes" in args:
            return json.dumps({"items": []})
        if "--all-namespaces" in args:
            return json.dumps({"items": self.other_states})
        if "patch" in args:
            self.objects[("configmap", installer.INSTALL_STATE)]["data"].update(
                json.loads(args[args.index("-p") + 1])["data"]
            )
            return ""
        if args[:2] == ["helm", "list"]:
            offset = int(args[args.index("--offset") + 1])
            return json.dumps(self.releases[offset : offset + 256])
        if args[:3] == ["helm", "get", "manifest"]:
            return self.manifests.get(args[3], "")
        if args[:2] == ["helm", "upgrade"]:
            if self.fail_dashboard and "openshell-dashboard" in args:
                raise RuntimeError("dashboard failed")
            self.objects[("secret", "openshell-client-tls")] = {
                "data": {"ca.crt": "Y2E="}
            }
            self.objects[("route", args[3])] = {
                "status": {
                    "ingress": [
                        {"conditions": [{"type": "Admitted", "status": "True"}]}
                    ]
                }
            }
            if not any(r["name"] == args[3] for r in self.releases):
                self.releases.append(
                    {
                        "name": args[3],
                        "chart": "helm-chart-0.1.3"
                        if args[3] == "openshell"
                        else "openshell-dashboard-0.1.0",
                    }
                )
        elif "get" in args and "--raw" not in args:
            start = args.index("get")
            obj = self.objects.get(tuple(args[start + 1 : start + 3]))
            return json.dumps(obj) if obj is not None else ""
        elif "create" in args:
            obj = json.loads(payload)
            key = (obj["kind"].lower(), obj["metadata"]["name"])
            if key in self.objects:
                raise RuntimeError("already exists")
            self.objects[key] = obj
        return ""


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = configuration()

    def load(self):
        path = self.root / "config.json"
        path.write_text(json.dumps(self.config))
        return installer.load_config(path)

    def cluster(self):
        secret = self.root / "client.txt"
        secret.write_text("a-secret-that-must-not-appear-in-argv\n")
        self.config["oidc"]["client_secret_file"] = str(secret)
        return FakeCluster(self.load())

    def test_rejects_unpinned_versions_and_unknown_keys(self):
        for version in (
            "latest",
            "0.0.0",
            "01.2.3",
            "1.2.3-01",
            ">=0.1.0",
            "REPLACE_ME",
        ):
            with self.subTest(version=version):
                self.config["gateway"]["version"] = version
                with self.assertRaises(ValueError):
                    self.load()
        self.config = configuration()
        self.config["oidc"]["client_secret"] = "never-inline"
        with self.assertRaisesRegex(ValueError, "Unknown"):
            self.load()

    def test_pinned_downstream_and_new_release_versions(self):
        for version in ("0.0.0-dev.e7fdd6b", "0.2.1", "1.2.3+rhaiv.5"):
            self.config["gateway"]["version"] = version
            self.assertEqual(self.load()["gateway"]["version"], version)

    def test_yaml_overlays_merge_in_order_and_preserve_managed_values(self):
        (self.root / "base.yaml").write_text(
            "resources:\n  requests:\n    cpu: 100m\n    memory: 256Mi\n"
        )
        (self.root / "site.yaml").write_text(
            "resources:\n  requests:\n    cpu: 200m\nimagePullSecrets:\n  - name: registry-creds\n"
        )
        self.config["gateway"]["values_files"] = ["base.yaml", "site.yaml"]
        self.config["oidc"]["scope"] = "openid email profile offline_access"
        gateway, dashboard = installer.chart_values(self.load())
        self.assertEqual(
            gateway["resources"]["requests"], {"cpu": "200m", "memory": "256Mi"}
        )
        self.assertEqual(gateway["imagePullSecrets"], [{"name": "registry-creds"}])
        self.assertEqual(
            gateway["server"]["sandboxNamespace"], self.config["namespace"]
        )
        self.assertEqual(
            dashboard["oidc"]["scope"], "openid email profile offline_access"
        )

    def test_overlays_cannot_replace_authentication_or_namespace_contract(self):
        for name, overlay in (
            ("gateway", "server:\n  auth:\n    allowUnauthenticatedUsers: true"),
            ("gateway", "server: null"),
            ("gateway", "fullnameOverride: foreign"),
            ("dashboard", "authProxy:\n  extraArgs: [--skip-auth-regex=.*]"),
            ("dashboard", "networkPolicy:\n  enabled: false"),
            ("dashboard", "oidc:\n  existingSecret: foreign"),
        ):
            with self.subTest(overlay=overlay):
                self.config = configuration()
                (self.root / "site.yaml").write_text(overlay)
                self.config[name]["values_files"] = ["site.yaml"]
                with self.assertRaises(ValueError):
                    self.load()

    def test_scope_and_system_namespace_validation(self):
        for scope in (None, [], "profile email", "openid\nemail"):
            self.config["oidc"]["scope"] = scope
            with self.assertRaises(ValueError):
                self.load()
        self.config = configuration()
        for ns in ("default", "openshift", "openshift-ingress", "kube-system"):
            self.config["namespace"] = ns
            with self.assertRaisesRegex(ValueError, "system namespace"):
                self.load()

    def test_preflight_storage_and_permissions_fail_before_mutation(self):
        for issue in ("storage", "permission", "workspace-storage"):
            cluster = self.cluster()
            if issue == "storage":
                cluster.storage = []
            elif issue == "permission":
                cluster.denied_permission = "deployments.apps"
            else:
                cluster.config["gateway"]["values"] = {
                    "server": {"workspaceStorageClass": "missing"}
                }
            with self.subTest(issue=issue), self.assertRaises(ValueError):
                cluster.install([], [])
            self.assertFalse(
                any(
                    "create" in args and "can-i" not in args
                    for args, _ in cluster.calls
                )
            )
            self.assertFalse(
                any(args[:2] == ["helm", "upgrade"] for args, _ in cluster.calls)
            )

    def test_cross_namespace_identity_reuse_is_rejected(self):
        for field in ("oidc-audience", "oidc-client-id"):
            cluster = self.cluster()
            other = {
                **cluster.identity_state(),
                "oidc-audience": "other-api",
                "oidc-client-id": "other-browser",
            }
            other[field] = cluster.identity_state()[field]
            cluster.other_states = [
                {
                    "metadata": {"name": installer.INSTALL_STATE, "namespace": "other"},
                    "data": other,
                }
            ]
            with (
                self.subTest(field=field),
                self.assertRaisesRegex(ValueError, "distinct per-gateway"),
            ):
                cluster.preflight()
        cluster.other_states[0]["data"]["oidc-issuer"] = (
            "https://another-issuer.example"
        )
        cluster.preflight()

    def test_identity_change_requires_migration(self):
        cluster = self.cluster()
        cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        cluster.config["oidc"]["audience"] = "different-api"
        with self.assertRaisesRegex(ValueError, "identity.*changed"):
            cluster.preflight()

    def test_uninstalled_other_release_history_does_not_block_install(self):
        cluster = self.cluster()
        cluster.objects[("namespace", cluster.ns)] = {"metadata": {}}
        cluster.releases = [
            {
                "name": "retired-gateway",
                "chart": "helm-chart-0.1.3",
                "status": "uninstalled",
            }
        ]
        cluster.manifests["retired-gateway"] = self.gateway_manifest()
        cluster.preflight()
        self.assertFalse(
            any(args[:3] == ["helm", "get", "manifest"] for args, _ in cluster.calls)
        )
        cluster.objects[("secret", "openshell-server-tls")] = {"data": {}}
        with self.assertRaisesRegex(ValueError, "explicit migration"):
            cluster.preflight()

    def test_preflight_rejects_credential_drift_without_changing_state(self):
        cluster = self.cluster()
        cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        before = copy.deepcopy(cluster.objects)
        Path(cluster.config["oidc"]["client_secret_file"]).write_text("changed")
        cluster.calls.clear()
        with self.assertRaisesRegex(ValueError, "rotate"):
            cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        self.assertEqual(cluster.objects, before)
        self.assertFalse(
            any("patch" in args and "can-i" not in args for args, _ in cluster.calls)
        )

    def test_preflight_mode_renders_and_checks_without_installing(self):
        path = self.root / "config.json"
        path.write_text(json.dumps(self.config))

        def run(_instance, args, payload=None):
            self.assertIsNone(payload)
            if args[:2] == ["helm", "pull"]:
                (Path(args[args.index("--destination") + 1]) / "chart.tgz").write_bytes(
                    b"fake"
                )
            return ""

        with (
            patch("sys.argv", ["install.py", "--config", str(path), "--preflight"]),
            patch.object(installer.shutil, "which", return_value="tool"),
            patch.object(installer.Installer, "run", run),
            patch.object(installer.Installer, "preflight") as preflight,
            patch.object(installer.Installer, "install") as install,
        ):
            installer.main()
        preflight.assert_called_once()
        install.assert_not_called()

    def test_rejects_invalid_oidc_and_namespace(self):
        for section, key, value in (
            ("oidc", "issuer", "http://issuer.example"),
            ("oidc", "issuer", "https://user:password@issuer.example"),
            ("oidc", "audience", configuration()["oidc"]["client_id"]),
            ("oidc", "allowed_roles", ["admin"]),
            ("gateway", "host", "gateway..example"),
        ):
            self.config = configuration()
            self.config[section][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.load()
        self.config = configuration()
        self.config["namespace"] = "openshell/another"
        with self.assertRaises(ValueError):
            self.load()

    def test_generated_connection_and_identity_contract(self):
        gateway, dashboard = installer.chart_values(self.load())
        self.assertIn(
            "openshell.openshell-team.svc.cluster.local",
            gateway["pkiInitJob"]["serverDnsNames"],
        )
        self.assertEqual(
            dashboard["gateway"]["url"],
            "grpcs://openshell.openshell-team.svc.cluster.local:8080",
        )
        self.assertEqual(
            gateway["server"]["oidc"]["issuer"], dashboard["oidc"]["issuer"]
        )
        # The dashboard decides who is entitled from the same two role names
        # the gateway enforces.
        for role in ("adminRole", "userRole"):
            self.assertEqual(dashboard["oidc"][role], gateway["server"]["oidc"][role])
        self.assertEqual(
            dashboard["dashboard"]["image"]["repository"],
            "opendatahub/odh-openshell-dashboard",
        )
        for component, repository in (
            ("gateway", "opendatahub/odh-openshell-gateway"),
            ("supervisor", "opendatahub/odh-openshell-supervisor"),
            ("sandboxRuntime", "opendatahub/odh-openshell-sandbox"),
        ):
            self.assertEqual(gateway[component]["image"]["repository"], repository)
        self.assertFalse(gateway["server"]["tls"]["enableMtls"])
        self.assertIsNone(gateway["securityContext"]["runAsUser"])

    def test_existing_admin_namespace_preserves_metadata_and_targets_releases(self):
        self.config["namespace"] = "research-team"
        cluster = self.cluster()
        namespace = {
            "metadata": {
                "name": cluster.ns,
                "labels": {"team": "research"},
                "annotations": {"openshift.io/sa.scc.uid-range": "1000100000/10000"},
            },
            "status": {"phase": "Active"},
        }
        cluster.objects[("namespace", cluster.ns)] = copy.deepcopy(namespace)
        cluster.install(["gateway.tgz", "dashboard.tgz"], ["g.json", "d.json"])
        cluster.install(["gateway.tgz", "dashboard.tgz"], ["g.json", "d.json"])
        self.assertEqual(cluster.objects[("namespace", cluster.ns)], namespace)
        self.assertEqual(
            {r["name"] for r in cluster.releases}, {"openshell", "openshell-dashboard"}
        )
        for args, payload in cluster.calls:
            if args[:2] == ["helm", "upgrade"]:
                self.assertEqual(args[args.index("--namespace") + 1], "research-team")
            if "create" in args and "can-i" not in args:
                resource = json.loads(payload)
                self.assertNotEqual(resource["kind"], "Namespace")
                self.assertEqual(resource["metadata"]["namespace"], "research-team")
        gateway, dashboard = installer.chart_values(cluster.config)
        self.assertEqual(gateway["server"]["sandboxNamespace"], "research-team")
        self.assertIn(
            "openshell.research-team.svc", gateway["pkiInitJob"]["serverDnsNames"]
        )
        self.assertEqual(
            dashboard["gateway"]["url"],
            "grpcs://openshell.research-team.svc.cluster.local:8080",
        )

    def test_namespace_override_validated_and_config_namespace_optional_with_override(
        self,
    ):
        self.config.pop("namespace")
        path = self.root / "config.json"
        path.write_text(json.dumps(self.config))
        self.assertEqual(
            installer.load_config(path, "admin-project")["namespace"], "admin-project"
        )
        with self.assertRaisesRegex(ValueError, "Invalid namespace"):
            installer.load_config(path, "invalid/namespace")
        with self.assertRaisesRegex(ValueError, "namespace"):
            installer.load_config(path)

    def test_existing_gateway_or_foreign_release_rejected_before_mutation(self):
        for release in (
            {"name": "another-gateway", "chart": "helm-chart-0.1.3"},
            {"name": "openshell", "chart": "helm-chart-0.1.3"},
            {"name": "openshell-dashboard", "chart": "other-chart-1.0.0"},
        ):
            with self.subTest(release=release):
                cluster = self.cluster()
                cluster.objects[("namespace", cluster.ns)] = {"metadata": {}}
                cluster.releases = [release]
                with self.assertRaises(ValueError):
                    cluster.install([], [])
                self.assertFalse(
                    any(
                        ("create" in args and "can-i" not in args)
                        or args[:2] == ["helm", "upgrade"]
                        for args, _ in cluster.calls
                    )
                )

    @staticmethod
    def gateway_manifest(kind="StatefulSet", container=None):
        return json.dumps(
            {
                "apiVersion": "apps/v1",
                "kind": kind,
                "metadata": {"name": "renamed-gateway"},
                "spec": {
                    "replicas": 0,
                    "template": {
                        "spec": {
                            "containers": [
                                container
                                or {
                                    "name": "openshell-gateway",
                                    "image": "registry.example/custom/runtime:1.0",
                                }
                            ]
                        }
                    },
                },
            }
        )

    def test_repackaged_gateway_rejected_before_mutation(self):
        for kind, status in (("StatefulSet", "deployed"), ("Deployment", "failed")):
            with self.subTest(kind=kind, status=status):
                cluster = self.cluster()
                cluster.objects[("namespace", cluster.ns)] = {"metadata": {}}
                cluster.releases = [
                    {"name": "team-gateway", "chart": "custom-1.0.0", "status": status}
                ]
                cluster.manifests["team-gateway"] = self.gateway_manifest(kind)
                before = copy.deepcopy(cluster.objects)
                with self.assertRaisesRegex(ValueError, "one gateway per namespace"):
                    cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
                self.assertEqual(cluster.objects, before)
                self.assertFalse(
                    any(args[:2] == ["helm", "upgrade"] for args, _ in cluster.calls)
                )

    def test_gateway_executable_detected_with_renamed_container(self):
        cluster = self.cluster()
        cluster.manifests["custom"] = self.gateway_manifest(
            container={
                "name": "server",
                "command": ["/usr/local/bin/openshell-gateway"],
            }
        )
        self.assertTrue(cluster.release_has_gateway("custom"))

    def test_unrelated_release_with_workload_is_preserved(self):
        cluster = self.cluster()
        cluster.objects[("namespace", cluster.ns)] = {"metadata": {}}
        cluster.releases = [{"name": "other-app", "chart": "custom-1.0.0"}]
        cluster.manifests["other-app"] = self.gateway_manifest(
            "Deployment", {"name": "web", "image": "registry.example/web:1.0"}
        )
        cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        self.assertIn("other-app", [release["name"] for release in cluster.releases])

    def test_invalid_release_manifest_stops_without_echoing_content(self):
        cluster = self.cluster()
        cluster.manifests["custom"] = "secret: [do-not-print-this"
        with self.assertRaisesRegex(ValueError, "Cannot inspect manifest") as caught:
            cluster.release_has_gateway("custom")
        self.assertNotIn("do-not-print-this", str(caught.exception))

    def test_conflict_on_later_release_page_is_detected(self):
        cluster = self.cluster()
        cluster.releases = [
            {"name": f"other-{i}", "chart": "unrelated-1.0.0"} for i in range(256)
        ]
        cluster.releases.append(
            {"name": "another-gateway", "chart": "helm-chart-0.1.3"}
        )
        with self.assertRaisesRegex(ValueError, "one gateway"):
            cluster.check_releases(managed=True)

    def test_terminating_namespace_is_rejected(self):
        cluster = self.cluster()
        cluster.objects[("namespace", cluster.ns)] = {
            "metadata": {},
            "status": {"phase": "Terminating"},
        }
        with self.assertRaisesRegex(ValueError, "terminating"):
            cluster.install([], [])

    def test_preexisting_gateway_certificate_is_not_reused(self):
        cluster = self.cluster()
        cluster.objects[("namespace", cluster.ns)] = {"metadata": {}}
        cluster.objects[("secret", "openshell-server-tls")] = {
            "data": {"tls.crt": "old"}
        }
        with self.assertRaisesRegex(ValueError, "explicit migration"):
            cluster.install([], [])

    def test_legacy_install_migrates_without_modifying_namespace(self):
        cluster = self.cluster()
        namespace = {
            "metadata": {
                "labels": {installer.OWNER: installer.OWNER_VALUE},
                "annotations": {
                    installer.GATEWAY_HOST: cluster.config["gateway"]["host"]
                },
            }
        }
        cluster.objects[("namespace", cluster.ns)] = copy.deepcopy(namespace)
        cluster.releases = [{"name": "openshell", "chart": "helm-chart-0.1.3"}]
        cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        self.assertEqual(cluster.objects[("namespace", cluster.ns)], namespace)
        self.assertEqual(
            cluster.objects[("configmap", installer.INSTALL_STATE)]["data"][
                "gateway-host"
            ],
            cluster.config["gateway"]["host"],
        )

    def test_missing_prerequisite_stops_before_mutation(self):
        cluster = self.cluster()
        cluster.objects.clear()
        with self.assertRaisesRegex(ValueError, "Agent Sandbox"):
            cluster.install([], [])
        self.assertFalse(
            any("create" in args and "can-i" not in args for args, _ in cluster.calls)
        )

    def test_install_order_context_and_secret_transport(self):
        cluster = self.cluster()
        cluster.install(["gateway.tgz", "dashboard.tgz"], ["g.json", "d.json"])
        helm = [args for args, _ in cluster.calls if args[0] == "helm"]
        self.assertEqual(
            [args[3] for args in helm], ["openshell", "openshell-dashboard"]
        )
        for args, _ in cluster.calls:
            self.assertNotIn("a-secret-that", " ".join(args))
            self.assertIn("test-context", args)
            self.assertNotIn("--atomic", args)
            self.assertNotIn("delete", args)
        data = cluster.objects[("secret", installer.OIDC_SECRET)]["data"]
        self.assertEqual(
            base64.b64decode(data["client-secret"]),
            b"a-secret-that-must-not-appear-in-argv",
        )
        cookie = base64.b64decode(data["cookie-secret"]).decode()
        self.assertEqual(len(base64.urlsafe_b64decode(cookie + "=")), 32)

    def test_rerun_preserves_secrets_without_input_file(self):
        cluster = self.cluster()
        cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        before = copy.deepcopy(cluster.objects[("secret", installer.OIDC_SECRET)])
        cluster.config["oidc"].pop("client_secret_file")
        cluster.calls.clear()
        cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        self.assertEqual(cluster.objects[("secret", installer.OIDC_SECRET)], before)
        self.assertFalse(
            any("create" in args and "can-i" not in args for args, _ in cluster.calls)
        )

    def test_first_install_requires_supplied_secret_even_with_existing_secret(self):
        for supplied in (None, "different", "matching"):
            with self.subTest(supplied=supplied):
                cluster = self.cluster()
                cluster.objects[("namespace", cluster.ns)] = {"metadata": {}}
                existing = {
                    "data": {
                        "client-secret": base64.b64encode(b"matching").decode(),
                        "cookie-secret": base64.b64encode(b"existing-cookie").decode(),
                    }
                }
                cluster.objects[("secret", installer.OIDC_SECRET)] = copy.deepcopy(
                    existing
                )
                path = Path(cluster.config["oidc"]["client_secret_file"])
                if supplied is None:
                    cluster.config["oidc"].pop("client_secret_file")
                else:
                    path.write_text(supplied)
                before = copy.deepcopy(cluster.objects)
                if supplied == "matching":
                    cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
                    self.assertEqual(
                        cluster.objects[("secret", installer.OIDC_SECRET)], existing
                    )
                else:
                    expected = (
                        "required for the first install"
                        if supplied is None
                        else "rotate"
                    )
                    with self.assertRaisesRegex(ValueError, expected):
                        cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
                    self.assertEqual(cluster.objects, before)

    def test_new_namespace_preflight_checks_files_without_namespaced_reads(self):
        (self.root / "issuer.pem").write_text("test CA")
        self.config["oidc"]["ca_file"] = "issuer.pem"
        cluster = self.cluster()
        before = copy.deepcopy(cluster.objects)
        self.assertIsNone(cluster.preflight())
        self.assertEqual(cluster.objects, before)
        self.assertFalse(
            any("-n" in args and "get" in args for args, _ in cluster.calls)
        )
        path = Path(cluster.config["oidc"]["client_secret_file"])
        secret = path.read_text()
        path.write_text("\n")
        with self.assertRaisesRegex(ValueError, "contains no secret"):
            cluster.preflight()
        self.assertEqual(cluster.objects, before)
        path.write_text(secret)
        cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        self.assertIn(("namespace", cluster.ns), cluster.objects)
        self.assertIn(("secret", installer.OIDC_SECRET), cluster.objects)
        self.assertIn(("configmap", installer.OIDC_CA), cluster.objects)

    def test_changed_gateway_host_requires_certificate_migration(self):
        cluster = self.cluster()
        cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        cluster.config["gateway"]["host"] = "other.apps.example.com"
        cluster.calls.clear()
        with self.assertRaisesRegex(ValueError, "certificate migration"):
            cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        self.assertFalse(
            any(
                args[0] == "helm" or ("create" in args and "can-i" not in args)
                for args, _ in cluster.calls
            )
        )

    def test_different_secret_is_not_silently_rotated(self):
        cluster = self.cluster()
        cluster.objects[("namespace", cluster.ns)] = {"metadata": {}}
        cluster.credentials()
        before = copy.deepcopy(cluster.objects)
        Path(cluster.config["oidc"]["client_secret_file"]).write_text("changed")
        with self.assertRaisesRegex(ValueError, "rotate"):
            cluster.credentials()
        self.assertEqual(cluster.objects, before)

    def test_private_ca_and_relative_path(self):
        (self.root / "issuer.pem").write_text("test CA")
        self.config["oidc"]["ca_file"] = "issuer.pem"
        cluster = self.cluster()
        cluster.objects[("namespace", cluster.ns)] = {"metadata": {}}
        cluster.credentials()
        gateway, dashboard = installer.chart_values(cluster.config)
        self.assertEqual(
            gateway["server"]["oidc"]["caConfigMapName"], installer.OIDC_CA
        )
        self.assertEqual(dashboard["oidc"]["caConfigMapName"], installer.OIDC_CA)
        self.assertEqual(
            cluster.objects[("configmap", installer.OIDC_CA)]["data"]["ca.crt"],
            "test CA",
        )

    def test_dashboard_failure_keeps_gateway_and_credentials(self):
        cluster = self.cluster()
        cluster.fail_dashboard = True
        with self.assertRaisesRegex(RuntimeError, "dashboard failed"):
            cluster.install(["g.tgz", "d.tgz"], ["g.json", "d.json"])
        self.assertIn(("namespace", cluster.ns), cluster.objects)
        self.assertIn(("secret", installer.OIDC_SECRET), cluster.objects)
        self.assertIn(("secret", "openshell-client-tls"), cluster.objects)
        self.assertFalse(
            any("delete" in args or "uninstall" in args for args, _ in cluster.calls)
        )

    def test_route_admission_waits_and_times_out(self):
        cluster = self.cluster()
        cluster.objects[("namespace", cluster.ns)] = {"metadata": {}}
        admitted = {
            "status": {
                "ingress": [{"conditions": [{"type": "Admitted", "status": "True"}]}]
            }
        }
        with (
            patch.object(cluster, "get", side_effect=[{}, admitted]),
            patch.object(installer.time, "sleep") as sleep,
        ):
            cluster.wait_for_route("openshell")
            sleep.assert_called_once()
        with (
            patch.object(installer.time, "monotonic", side_effect=[0, 601]),
            self.assertRaisesRegex(ValueError, "not admitted"),
        ):
            cluster.wait_for_route("openshell")

    def test_render_failure_prevents_cluster_access(self):
        path = self.root / "config.json"
        path.write_text(json.dumps(self.config))
        commands = []

        def run(_instance, args, payload=None):
            self.assertIsNone(payload)
            commands.append(args)
            if args[:2] == ["helm", "pull"]:
                destination = Path(args[args.index("--destination") + 1])
                (destination / "chart.tgz").write_bytes(b"fake")
                return ""
            raise RuntimeError("invalid chart values")

        with (
            patch("sys.argv", ["install.py", "--config", str(path)]),
            patch.object(installer.shutil, "which", return_value="tool"),
            patch.object(installer.Installer, "run", run),
            self.assertRaisesRegex(RuntimeError, "invalid chart values"),
        ):
            installer.main()
        self.assertTrue(all(args[0] == "helm" for args in commands))

    def test_check_only_never_calls_kubectl(self):
        path = self.root / "config.json"
        path.write_text(json.dumps(self.config))
        for chart in ("gateway", "dashboard"):
            (self.root / chart).mkdir()
            (self.root / chart / "Chart.yaml").write_text("version: 0.0.0\n")
        argv = [
            "install.py",
            "--config",
            str(path),
            "--check",
            "--namespace",
            "render-project",
            "--gateway-chart-directory",
            str(self.root / "gateway"),
            "--dashboard-chart-directory",
            str(self.root / "dashboard"),
        ]
        with (
            patch("sys.argv", argv),
            patch.object(installer.shutil, "which", return_value="helm"),
            patch.object(installer.Installer, "run", return_value="") as run,
        ):
            installer.main()
        self.assertEqual(run.call_count, 2)
        for call in run.call_args_list:
            self.assertEqual(call.args[0][:2], ["helm", "template"])
            args = call.args[0]
            self.assertEqual(args[args.index("--namespace") + 1], "render-project")


if __name__ == "__main__":
    unittest.main()
