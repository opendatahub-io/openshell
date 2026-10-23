#!/usr/bin/env -S uv run --script
# SPDX-FileCopyrightText: Copyright (c) 2026 OpenShell contributors
# SPDX-License-Identifier: Apache-2.0
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Install the gateway and dashboard as separate Helm releases on OpenShift."""

import argparse
import base64
import copy
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

import yaml

OWNER = "openshell.ai/installer"
OWNER_VALUE = "odh-dashboard"
GATEWAY_HOST = "openshell.ai/installer-gateway-host"
INSTALL_STATE = "openshell-installer"
OIDC_SECRET = "openshell-dashboard-oidc"
OIDC_CA = "openshell-oidc-ca"
VERSION = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
DNS = re.compile(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?")

# Expose operational chart settings without allowing overlays to replace the
# installer's identity, TLS, service naming, or namespace contract.
COMMON_VALUES = dict.fromkeys(
    ("resources", "nodeSelector", "tolerations", "affinity", "imagePullSecrets")
)
EXTRA_VALUES = {
    "gateway": {
        **COMMON_VALUES,
        "server": dict.fromkeys(
            (
                "workspaceStorageClass",
                "workspaceDefaultStorageSize",
                "defaultRuntimeClassName",
                "sandboxImagePullSecrets",
            )
        ),
        "openshiftRoute": {"annotations": None},
    },
    "dashboard": {
        **COMMON_VALUES,
        "authProxy": {
            "resources": None,
            "cookie": {"refresh": None},
            "upstreamTimeout": None,
        },
        "networkPolicy": {"ingressNamespace": None, "ingressFrom": None},
        "openshiftRoute": {"annotations": None},
    },
}


def merge_values(target, overlay, allowed, prefix=""):
    require(isinstance(overlay, dict), f"{prefix or 'Values'} must be a mapping")
    for key, value in overlay.items():
        require(
            key in allowed, f"Unsupported or installer-owned Helm value: {prefix}{key}"
        )
        if allowed[key] is not None:
            merge_values(
                target.setdefault(key, {}), value, allowed[key], f"{prefix}{key}."
            )
        elif isinstance(value, dict) and isinstance(target.get(key), dict):
            # Helm's map merge semantics; arrays/scalars are replaced.
            merge_unrestricted(target[key], value)
        else:
            target[key] = copy.deepcopy(value)


def merge_unrestricted(target, overlay):
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            merge_unrestricted(target[key], value)
        else:
            target[key] = copy.deepcopy(value)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fields(obj, required, optional=()):
    require(isinstance(obj, dict), "Configuration sections must be JSON objects")
    require(
        not (set(obj) - set(required) - set(optional)),
        f"Unknown configuration fields: {set(obj) - set(required) - set(optional)}",
    )
    for key in required:
        require(key in obj and obj[key] != "", f"Missing configuration field: {key}")


def load_config(path, namespace=None):
    config = json.loads(path.read_text())
    if namespace is not None:
        require(isinstance(config, dict), "Configuration must be a JSON object")
        config["namespace"] = namespace
    fields(
        config,
        ("namespace", "context", "gateway", "dashboard", "oidc"),
        ("agent_sandbox_namespace", "agent_sandbox_deployment"),
    )
    ns = config["namespace"]
    require(
        isinstance(ns, str)
        and len(ns) <= 63
        and re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", ns),
        "Invalid namespace",
    )
    require(
        ns not in ("default", "openshift", "kube-system", "kube-public")
        and not ns.startswith(("kube-", "openshift-")),
        "Choose an application namespace, not a Kubernetes/OpenShift system namespace",
    )
    for key in ("agent_sandbox_namespace", "agent_sandbox_deployment"):
        if key in config:
            require(
                isinstance(config[key], str) and DNS.fullmatch(config[key]),
                f"Invalid {key}",
            )
    require(
        isinstance(config["context"], str) and config["context"].strip(),
        "context is required",
    )
    for name in ("gateway", "dashboard"):
        item = config[name]
        fields(item, ("chart", "version", "host"), ("images", "values_files"))
        require(
            isinstance(item["chart"], str) and item["chart"].startswith("oci://"),
            f"{name}.chart must be an OCI chart reference",
        )
        require(
            isinstance(item["version"], str) and VERSION.fullmatch(item["version"]),
            f"{name}.version must be exact SemVer (no latest or version ranges)",
        )
        require(
            item["version"] != "0.0.0",
            "Use a published release or pinned development version",
        )
        sources = item.get("values_files", [])
        require(
            isinstance(sources, list)
            and all(isinstance(p, str) and p for p in sources),
            f"{name}.values_files must be a list of file paths",
        )
        overrides = {}
        for source in sources:
            # SafeLoader does not construct Python objects. Do not include file
            # contents in diagnostics: user-supplied files may contain secrets.
            try:
                overlay = yaml.safe_load((path.parent / source).read_text())
            except yaml.YAMLError:
                raise ValueError(f"Invalid YAML in {name} values file") from None
            merge_values(overrides, overlay, EXTRA_VALUES[name])
        item["values"] = overrides
        host = item["host"]
        require(
            isinstance(host, str)
            and len(host) <= 253
            and DNS.fullmatch(host)
            and all(
                0 < len(label) <= 63
                and not label.startswith("-")
                and not label.endswith("-")
                for label in host.split(".")
            ),
            f"Invalid {name}.host",
        )
        components = (
            ("gateway", "supervisor", "sandboxRuntime", "sandbox")
            if name == "gateway"
            else ("dashboard", "authProxy")
        )
        fields(item.get("images", {}), (), components)
        for component, image in item.get("images", {}).items():
            keys = (
                ("repository", "tag", "digest")
                if component == "sandbox"
                else ("registry", "repository", "tag", "digest")
            )
            fields(image, (), keys)
            require(
                all(isinstance(value, str) for value in image.values()),
                "Image values must be strings",
            )
    require(
        config["gateway"]["host"] != config["dashboard"]["host"],
        "Gateway and dashboard need distinct hosts",
    )
    oidc = config["oidc"]
    fields(
        oidc,
        ("issuer", "client_id", "audience", "roles_claim", "admin_role", "user_role"),
        (
            "provider",
            "allowed_groups",
            "allowed_roles",
            "client_secret_file",
            "ca_file",
            "scope",
        ),
    )
    for key in (
        "issuer",
        "client_id",
        "audience",
        "roles_claim",
        "admin_role",
        "user_role",
    ):
        require(
            isinstance(oidc[key], str) and oidc[key].strip(),
            f"oidc.{key} must be a nonempty string",
        )
    issuer = urlsplit(oidc["issuer"])
    require(
        issuer.scheme == "https"
        and issuer.hostname
        and not issuer.username
        and not issuer.password
        and not issuer.query
        and not issuer.fragment,
        "OIDC issuer must be an HTTPS URL",
    )
    require(
        oidc["client_id"] != oidc["audience"],
        "Browser client ID and gateway audience must be distinct",
    )
    require(
        oidc["admin_role"] != oidc["user_role"], "Admin and user roles must be distinct"
    )
    require(
        oidc.get("provider", "oidc") in ("oidc", "keycloak-oidc"),
        "Unsupported OIDC provider",
    )
    for key in ("allowed_groups", "allowed_roles"):
        require(
            isinstance(oidc.get(key, []), list)
            and all(isinstance(v, str) and v for v in oidc.get(key, [])),
            f"oidc.{key} must be a list of strings",
        )
    require(
        not oidc.get("allowed_roles") or oidc.get("provider") == "keycloak-oidc",
        "allowed_roles requires keycloak-oidc; use allowed_groups for generic OIDC",
    )
    if "scope" in oidc:
        require(
            isinstance(oidc["scope"], str)
            and re.fullmatch(
                r"[\x21\x23-\x5B\x5D-\x7E]+(?: [\x21\x23-\x5B\x5D-\x7E]+)*",
                oidc["scope"],
            )
            and "openid" in oidc["scope"].split(),
            "oidc.scope must be space-separated OAuth scopes including openid",
        )
    for key in ("client_secret_file", "ca_file"):
        if oidc.get(key):
            source = (path.parent / oidc[key]).resolve()
            require(
                source.is_file() and source.stat().st_size > 0,
                f"Missing or empty oidc.{key}",
            )
            oidc[key] = str(source)
    return config


def chart_values(config):
    ns, oidc = config["namespace"], config["oidc"]
    ca = OIDC_CA if oidc.get("ca_file") else ""
    security = {"runAsUser": None, "seccompProfile": {"type": "RuntimeDefault"}}
    gateway = {
        "fullnameOverride": "openshell",
        "podSecurityContext": None,
        "securityContext": security,
        "replicaCount": 1,
        "server": {
            "disableTls": False,
            "sandboxNamespace": ns,
            "auth": {"allowUnauthenticatedUsers": False},
            "tls": {
                "enableMtls": False,
                "clientCaSecretName": "",
                "certSecretName": "openshell-server-tls",
                "clientTlsSecretName": "openshell-client-tls",
            },
            "oidc": {
                "issuer": oidc["issuer"],
                "audience": oidc["audience"],
                "rolesClaim": oidc["roles_claim"],
                "adminRole": oidc["admin_role"],
                "userRole": oidc["user_role"],
                "caConfigMapName": ca,
            },
        },
        "pkiInitJob": {
            "enabled": True,
            "serverDnsNames": [
                config["gateway"]["host"],
                f"openshell.{ns}.svc",
                f"openshell.{ns}.svc.cluster.local",
            ],
        },
        "openshiftRoute": {"enabled": True, "host": config["gateway"]["host"]},
    }
    dashboard = {
        "fullnameOverride": "openshell-dashboard",
        "podSecurityContext": None,
        "securityContext": security,
        "gateway": {
            "url": f"grpcs://openshell.{ns}.svc.cluster.local:8080",
            "caSecretName": "openshell-client-tls",
        },
        "oidc": {
            "provider": oidc.get("provider", "oidc"),
            "issuer": oidc["issuer"],
            "clientId": oidc["client_id"],
            "existingSecret": OIDC_SECRET,
            "audience": oidc["audience"],
            "rolesClaim": oidc["roles_claim"],
            "adminRole": oidc["admin_role"],
            "userRole": oidc["user_role"],
            "codeChallengeMethod": "S256",
            "allowedGroups": oidc.get("allowed_groups", []),
            "allowedRoles": oidc.get("allowed_roles", []),
            "caConfigMapName": ca,
            "scope": oidc.get("scope", ""),
        },
        "openshiftRoute": {
            "enabled": True,
            "host": config["dashboard"]["host"],
            "termination": "edge",
        },
        "networkPolicy": {"ingressNamespace": "openshift-ingress"},
    }
    for name, values in (("gateway", gateway), ("dashboard", dashboard)):
        merge_values(values, config[name].get("values", {}), EXTRA_VALUES[name])
        for component, image in config[name].get("images", {}).items():
            values.setdefault(component, {})["image"] = image
    return gateway, dashboard


class Installer:
    def __init__(self, config, timeout):
        self.config = config
        self.timeout = timeout
        self.kube = ["kubectl", "--context", config["context"], "--request-timeout=30s"]
        self.ns = config["namespace"]

    def run(self, args, payload=None):
        # Never log stdin: it can contain Secret data. Do not echo commands.
        result = subprocess.run(
            args, input=payload, text=True, capture_output=True, check=False
        )
        if result.returncode:
            raise RuntimeError(f"{args[0]} failed: {result.stderr.strip()}")
        return result.stdout

    def get(self, kind, name, namespaced=True):
        args = self.kube + (["-n", self.ns] if namespaced else [])
        output = self.run(
            [*args, "get", kind, name, "--ignore-not-found", "-o", "json"]
        )
        return json.loads(output) if output.strip() else None

    def create(self, resource):
        self.run([*self.kube, "create", "-f", "-"], json.dumps(resource))

    def release_has_gateway(self, release):
        # Chart names and images can change in downstream packages. Inspect the
        # stored workload instead, including failed releases with no running pod.
        manifest = self.run(
            [
                "helm",
                "get",
                "manifest",
                release,
                "--kube-context",
                self.config["context"],
                "--namespace",
                self.ns,
            ]
        )
        try:
            for resource in yaml.safe_load_all(manifest):
                if not isinstance(resource, dict):
                    continue
                if resource.get("kind") == "Pod":
                    pod = resource
                elif resource.get("kind") in ("Deployment", "StatefulSet", "DaemonSet"):
                    pod = resource.get("spec", {}).get("template", {})
                else:
                    continue
                for container in pod.get("spec", {}).get("containers", []):
                    if container.get("name") == "openshell-gateway" or any(
                        Path(arg).name == "openshell-gateway"
                        for arg in container.get("command", [])
                    ):
                        return True
        except yaml.YAMLError:
            # Helm manifests can contain Secrets; never include parser excerpts.
            raise ValueError(f"Cannot inspect manifest for release {release}") from None
        return False

    def check_releases(self, managed):
        # Explicit status flags work with both Helm 3 and Helm 4. Paginate so a
        # busy administrator-managed namespace cannot hide a conflicting release.
        offset = 0
        while True:
            releases = json.loads(
                self.run(
                    [
                        "helm",
                        "list",
                        "--kube-context",
                        self.config["context"],
                        "--namespace",
                        self.ns,
                        "--output",
                        "json",
                        "--max",
                        "256",
                        "--offset",
                        str(offset),
                        "--deployed",
                        "--failed",
                        "--pending",
                        "--uninstalling",
                        "--uninstalled",
                        "--superseded",
                    ]
                )
            )
            for release in releases:
                name = release["name"]
                # --keep-history leaves an uninstalled record, not a gateway.
                # Keep fixed-name ownership checks: Helm still owns that history.
                if release.get("status") == "uninstalled" and name not in (
                    "openshell",
                    "openshell-dashboard",
                ):
                    continue
                require(
                    managed or name not in ("openshell", "openshell-dashboard"),
                    f"Release {name} already exists outside this installer; migrate it explicitly",
                )
                if name != "openshell":
                    gateway = release.get("chart", "").startswith(
                        "helm-chart-"
                    ) or self.release_has_gateway(name)
                    require(
                        not gateway,
                        f"Namespace {self.ns} already has gateway release {name}; use one gateway per namespace",
                    )
            if len(releases) < 256:
                break
            offset += len(releases)

    def cluster_checks(self, namespace):
        version = self.get("clusterversion.config.openshift.io", "version", False)
        print(
            f"OpenShift: {(version or {}).get('status', {}).get('desired', {}).get('version', 'unknown')}"
        )
        storage = json.loads(
            self.run([*self.kube, "get", "storageclasses", "-o", "json"])
        )
        defaults = [
            item["metadata"]["name"]
            for item in storage["items"]
            if any(
                item["metadata"].get("annotations", {}).get(key) == "true"
                for key in (
                    "storageclass.kubernetes.io/is-default-class",
                    "storageclass.beta.kubernetes.io/is-default-class",
                )
            )
        ]
        require(
            defaults,
            "No default StorageClass; the gateway chart's SQLite PVC requires one",
        )
        print(
            f"Default storage: {', '.join(defaults)} (verify block-backed SQLite storage)"
        )
        custom = (
            self.config["gateway"]
            .get("values", {})
            .get("server", {})
            .get("workspaceStorageClass")
        )
        if custom:
            require(
                any(item["metadata"]["name"] == custom for item in storage["items"]),
                "Configured workspaceStorageClass does not exist",
            )
        nodes = json.loads(self.run([*self.kube, "get", "nodes", "-o", "json"]))
        kernels = sorted(
            {
                item.get("status", {})
                .get("nodeInfo", {})
                .get("kernelVersion", "unknown")
                for item in nodes["items"]
            }
        )
        print(f"Node kernels: {', '.join(kernels) or 'none reported'}")
        if any(
            (match := re.match(r"(\d+)\.(\d+)", kernel))
            and tuple(map(int, match.groups())) < (5, 19)
            for kernel in kernels
        ):
            print(
                "Note: kernels before 5.19 need an OpenShell build with the legacy-kernel fixes; verify sandbox networking."
            )
        # Check actual installation operations instead of requiring wildcard
        # cluster-admin. These checks cannot prove RBAC bind/escalate or SCC admission.
        scoped = [
            "secrets",
            "configmaps",
            "services",
            "serviceaccounts",
            "deployments.apps",
            "statefulsets.apps",
            "jobs.batch",
            "roles.rbac.authorization.k8s.io",
            "rolebindings.rbac.authorization.k8s.io",
            "routes.route.openshift.io",
            "networkpolicies.networking.k8s.io",
        ]
        operations = [
            (verb, resource, True)
            for resource in scoped
            for verb in ("create", "patch")
        ]
        operations += [
            (verb, resource, False)
            for resource in (
                "clusterroles.rbac.authorization.k8s.io",
                "clusterrolebindings.rbac.authorization.k8s.io",
            )
            for verb in ("create", "patch")
        ]
        if not namespace:
            operations.append(("create", "namespaces", False))
        for verb, resource, namespaced in operations:
            try:
                answer = self.run(
                    [
                        *self.kube,
                        "auth",
                        "can-i",
                        verb,
                        resource,
                        *(["-n", self.ns] if namespaced else []),
                    ]
                )
                require(answer.strip() == "yes", "denied")
            except (RuntimeError, ValueError):
                raise ValueError(
                    f"Preflight permission check failed: {verb} {resource}"
                    + (f" in {self.ns}" if namespaced else " cluster-wide")
                ) from None

    def identity_state(self):
        return {
            "gateway-host": self.config["gateway"]["host"],
            **{
                f"oidc-{key.replace('_', '-')}": self.config["oidc"][key]
                for key in ("issuer", "audience", "client_id")
            },
        }

    def check_identity(self, state):
        desired = self.identity_state()
        for key, value in (state or {}).get("data", {}).items():
            if key in desired:
                require(
                    value == desired[key],
                    f"Installer identity {key} changed; explicit identity/certificate migration is required",
                )
        states = json.loads(
            self.run(
                [
                    *self.kube,
                    "get",
                    "configmaps",
                    "--all-namespaces",
                    "-l",
                    f"{OWNER}={OWNER_VALUE}",
                    "-o",
                    "json",
                ]
            )
        )
        for other in states["items"]:
            if (
                other["metadata"]["name"] != INSTALL_STATE
                or other["metadata"].get("namespace") == self.ns
            ):
                continue
            data = other.get("data", {})
            if "oidc-issuer" not in data:
                print(
                    f"Note: legacy installer state in {other['metadata']['namespace']} has no identity metadata; verify audience isolation manually."
                )
                continue
            if data["oidc-issuer"].rstrip("/") == desired["oidc-issuer"].rstrip("/"):
                require(
                    data.get("oidc-audience") != desired["oidc-audience"]
                    and data.get("oidc-client-id") != desired["oidc-client-id"],
                    f"OIDC audience/browser client already used by namespace {other['metadata']['namespace']}; provision distinct per-gateway registrations",
                )

    def preflight(self):
        self.run([*self.kube, "get", "--raw", "/apis/route.openshift.io/v1"])
        crd = self.get("crd", "sandboxes.agents.x-k8s.io", False)
        require(
            crd
            and any(
                v["served"] and v["name"] in ("v1alpha1", "v1beta1")
                for v in crd["spec"]["versions"]
            ),
            "Install the Agent Sandbox CRDs and controller first",
        )
        self.run(
            [
                *self.kube,
                "-n",
                self.config.get("agent_sandbox_namespace", "agent-sandbox-system"),
                "rollout",
                "status",
                "deployment/"
                + self.config.get(
                    "agent_sandbox_deployment", "agent-sandbox-controller"
                ),
                "--timeout",
                self.timeout,
            ]
        )
        namespace = self.get("namespace", self.ns, False)
        require(
            not namespace or namespace.get("status", {}).get("phase") != "Terminating",
            "Namespace is terminating",
        )
        self.cluster_checks(namespace)
        state = self.get("configmap", INSTALL_STATE) if namespace else None
        require(
            not state or state["metadata"].get("labels", {}).get(OWNER) == OWNER_VALUE,
            f"ConfigMap {INSTALL_STATE} already exists outside this installer",
        )
        # Preserve compatibility with installations made before state moved off
        # the Namespace. Never modify administrator-owned Namespace metadata.
        legacy_host = (
            (namespace or {})
            .get("metadata", {})
            .get("annotations", {})
            .get(GATEWAY_HOST)
        )
        original_host = (
            state.get("data", {}).get("gateway-host") if state else legacy_host
        )
        require(
            not (state or legacy_host)
            or original_host == self.config["gateway"]["host"],
            "Gateway hostname differs from the original install; certificate migration is required",
        )
        self.check_identity(state)
        if namespace:
            self.check_releases(managed=bool(state or legacy_host))
            # The chart's bootstrap hook reuses existing TLS material. Do not
            # accidentally use certificates belonging to another gateway.
            if not (state or legacy_host):
                for secret in (
                    "openshell-server-tls",
                    "openshell-client-tls",
                    "openshell-jwt-keys",
                ):
                    require(
                        not self.get("secret", secret),
                        f"Existing gateway Secret {secret} requires explicit migration",
                    )
        require(
            state or legacy_host or self.config["oidc"].get("client_secret_file"),
            "oidc.client_secret_file is required for the first install",
        )
        self.credentials(check_only=True, namespace_exists=bool(namespace))
        return namespace

    def credentials(self, check_only=False, *, namespace_exists=True):
        require(
            namespace_exists or check_only, "Create the namespace before credentials"
        )
        oidc = self.config["oidc"]
        existing = self.get("secret", OIDC_SECRET) if namespace_exists else None
        supplied = (
            Path(oidc["client_secret_file"]).read_bytes().rstrip(b"\r\n")
            if oidc.get("client_secret_file")
            else None
        )
        if supplied is not None:
            require(supplied, "Client secret file contains no secret")
        if existing:
            data = existing.get("data", {})
            require(
                data.get("client-secret") and data.get("cookie-secret"),
                "Existing OIDC Secret is missing required keys",
            )
            require(
                supplied is None or base64.b64decode(data["client-secret"]) == supplied,
                "OIDC Secret differs from file; rotate it explicitly before rerunning",
            )
        else:
            require(supplied, "Client secret file is required")
            if not check_only:
                self.create(
                    {
                        "apiVersion": "v1",
                        "kind": "Secret",
                        "type": "Opaque",
                        "metadata": {"name": OIDC_SECRET, "namespace": self.ns},
                        "data": {
                            "client-secret": base64.b64encode(supplied).decode(),
                            "cookie-secret": base64.b64encode(
                                secrets.token_urlsafe(32).encode()
                            ).decode(),
                        },
                    }
                )
        if oidc.get("ca_file"):
            ca = Path(oidc["ca_file"]).read_text()
            existing_ca = self.get("configmap", OIDC_CA) if namespace_exists else None
            require(
                not existing_ca or existing_ca.get("data", {}).get("ca.crt") == ca,
                "OIDC CA differs; rotate the ConfigMap and restart both releases explicitly",
            )
            if not existing_ca and not check_only:
                self.create(
                    {
                        "apiVersion": "v1",
                        "kind": "ConfigMap",
                        "metadata": {"name": OIDC_CA, "namespace": self.ns},
                        "data": {"ca.crt": ca},
                    }
                )

    def wait_for_route(self, release):
        seconds = (
            int(self.timeout[:-1]) * {"s": 1, "m": 60, "h": 3600}[self.timeout[-1]]
        )
        deadline = time.monotonic() + seconds
        while True:
            route = self.get("route", release)
            if route and any(
                condition.get("type") == "Admitted"
                and condition.get("status") == "True"
                for ingress in route.get("status", {}).get("ingress", [])
                for condition in ingress.get("conditions", [])
            ):
                return
            require(
                time.monotonic() < deadline,
                f"Route {release} is not admitted; inspect it and rerun",
            )
            time.sleep(min(2, max(0, deadline - time.monotonic())))

    def install(self, charts, values):
        namespace = self.preflight()
        if not namespace:
            self.create(
                {
                    "apiVersion": "v1",
                    "kind": "Namespace",
                    "metadata": {
                        "name": self.ns,
                        "labels": {OWNER: OWNER_VALUE},
                    },
                }
            )
        if not self.get("configmap", INSTALL_STATE):
            self.create(
                {
                    "apiVersion": "v1",
                    "kind": "ConfigMap",
                    "metadata": {
                        "name": INSTALL_STATE,
                        "namespace": self.ns,
                        "labels": {OWNER: OWNER_VALUE},
                    },
                    "data": self.identity_state(),
                }
            )
        else:
            # Add identity metadata to legacy state only after preflight passed.
            self.run(
                [
                    *self.kube,
                    "-n",
                    self.ns,
                    "patch",
                    "configmap",
                    INSTALL_STATE,
                    "--type=merge",
                    "-p",
                    json.dumps({"data": self.identity_state()}),
                ]
            )
        self.credentials()
        for index, release in enumerate(("openshell", "openshell-dashboard")):
            print(f"Installing {release} in {self.ns}...", flush=True)
            self.run(
                [
                    "helm",
                    "upgrade",
                    "--install",
                    release,
                    str(charts[index]),
                    "--kube-context",
                    self.config["context"],
                    "--namespace",
                    self.ns,
                    "--values",
                    str(values[index]),
                    "--reset-values",
                    "--wait",
                    "--wait-for-jobs",
                    "--timeout",
                    self.timeout,
                    "--history-max",
                    "5",
                ]
            )
            if index == 0:
                ca = self.get("secret", "openshell-client-tls")
                require(
                    ca and ca.get("data", {}).get("ca.crt"),
                    "Gateway did not create its CA Secret",
                )
            self.wait_for_route(release)
        print(f"Dashboard: https://{self.config['dashboard']['host']}")
        print(f"Gateway: https://{self.config['gateway']['host']}")
        print(
            "Register the gateway with the CLI using its CA, then log in through customer OIDC."
        )
        print(
            "An administrator must add users to workspaces. Verify login, denied access, sandbox creation and terminals."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument(
        "--namespace",
        help="Administrator-selected namespace; overrides config.namespace (created if missing)",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="Validate and render charts without accessing the cluster",
    )
    mode.add_argument(
        "--preflight",
        action="store_true",
        help="Render charts and check cluster prerequisites without installing",
    )
    parser.add_argument(
        "--gateway-chart-directory",
        type=Path,
        help="Local source chart for --check only",
    )
    parser.add_argument(
        "--dashboard-chart-directory",
        type=Path,
        help="Local source chart for --check only",
    )
    parser.add_argument(
        "--timeout", default="10m", help="Helm/controller wait timeout (default: 10m)"
    )
    args = parser.parse_args()
    require(
        args.check
        or not (args.gateway_chart_directory or args.dashboard_chart_directory),
        "Local source charts are only supported with --check; install versioned OCI artifacts",
    )
    require(
        re.fullmatch(r"[1-9][0-9]*[smh]", args.timeout),
        "Timeout must be a positive duration such as 10m",
    )
    for tool in ["helm"] if args.check else ["helm", "kubectl"]:
        require(shutil.which(tool), f"Required tool not found: {tool}")
    config = load_config(args.config.resolve(), args.namespace)
    installer = Installer(config, args.timeout)
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="openshell-install-") as temporary:
        root = Path(temporary)
        charts, files = [], []
        for index, (name, values, local) in enumerate(
            zip(
                ("gateway", "dashboard"),
                chart_values(config),
                (args.gateway_chart_directory, args.dashboard_chart_directory),
                strict=True,
            )
        ):
            if local:
                chart = local.resolve()
                require((chart / "Chart.yaml").is_file(), f"Missing chart: {chart}")
                # Source charts carry 0.0.0; render with the requested release image tag.
                values.setdefault("global", {})["image"] = {
                    "tag": config[name]["version"]
                }
            else:
                destination = root / name
                destination.mkdir()
                installer.run(
                    [
                        "helm",
                        "pull",
                        config[name]["chart"],
                        "--version",
                        config[name]["version"],
                        "--destination",
                        str(destination),
                    ]
                )
                packages = list(destination.glob("*.tgz"))
                require(len(packages) == 1, f"Expected one downloaded {name} chart")
                chart = packages[0]
            value_file = root / f"{name}.json"
            value_file.write_text(json.dumps(values))
            release = ("openshell", "openshell-dashboard")[index]
            installer.run(
                [
                    "helm",
                    "template",
                    release,
                    str(chart),
                    "--namespace",
                    config["namespace"],
                    "--values",
                    str(value_file),
                    "--api-versions",
                    "route.openshift.io/v1",
                    "--api-versions",
                    "agents.x-k8s.io/v1beta1",
                ]
            )
            charts.append(chart)
            files.append(value_file)
        print(
            "Both charts rendered successfully. This does not verify cluster or API compatibility.",
            flush=True,
        )
        if args.preflight:
            installer.preflight()
            print("Cluster preflight passed; no installation resources were changed.")
        elif not args.check:
            installer.install(charts, files)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError, TypeError) as error:
        print(
            f"Installation stopped: {error}\nCluster resources were not rolled back or deleted.",
            file=sys.stderr,
        )
        sys.exit(1)
