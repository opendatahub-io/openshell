#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Image provenance verification for downstream OpenShift CI.
#
# After an e2e run, verifies that every container image observed on pods in
# the target namespace — plus the supervisor image referenced from the
# gateway's rendered config (it never runs as its own pod in these test
# flows) — came from an authorized downstream registry, and that no
# container has regressed away from imagePullPolicy=IfNotPresent.
#
# Usage:
#   e2e/rust/tests/odh/verify-image-provenance.sh [--namespace NS] [--release NAME]
#
# Required:
#   ALLOWED_IMAGE_REGISTRY_PREFIXES  Comma-separated allowed image registry
#                                    prefixes, e.g.
#                                    "registry.redhat.io/,brew.registry.redhat.io/"
#                                    No default: an empty list would silently
#                                    approve any image, defeating the check.
#
# Ref: inspired by https://github.com/openshift/origin/pull/22230

set -euo pipefail

NAMESPACE="${NAMESPACE:-openshell}"
RELEASE="${RELEASE:-openshell}"
ALLOWED_IMAGE_REGISTRY_PREFIXES="${ALLOWED_IMAGE_REGISTRY_PREFIXES:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --release)   RELEASE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log() { echo "==> $*"; }

if [ -z "$ALLOWED_IMAGE_REGISTRY_PREFIXES" ]; then
  echo "ERROR: ALLOWED_IMAGE_REGISTRY_PREFIXES must be set to a comma-separated" >&2
  echo "       list of allowed downstream registry prefixes, e.g.:" >&2
  echo '       ALLOWED_IMAGE_REGISTRY_PREFIXES="registry.redhat.io/,brew.registry.redhat.io/"' >&2
  exit 1
fi

log "Verifying image provenance for namespace=$NAMESPACE release=$RELEASE"

pods_json="$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" -o json 2>/dev/null || echo '{"items":[]}')"

cm_name="${RELEASE}-config"
supervisor_image="$(oc get configmap "$cm_name" -n "$NAMESPACE" -o jsonpath='{.data.gateway\.toml}' 2>/dev/null \
  | sed -n 's/^ *supervisor_image *= *"\(.*\)"$/\1/p')"

ALLOWED_IMAGE_REGISTRY_PREFIXES="$ALLOWED_IMAGE_REGISTRY_PREFIXES" \
SUPERVISOR_IMAGE_REF="$supervisor_image" \
python3 - "$pods_json" <<'PY'
import json
import os
import sys

pods = json.loads(sys.argv[1])
allowed = [p for p in os.environ["ALLOWED_IMAGE_REGISTRY_PREFIXES"].split(",") if p]
supervisor_image = os.environ.get("SUPERVISOR_IMAGE_REF", "")

errors = []
images = []  # (source, image)


def check_pull_policies(pod_name, containers):
    for c in containers or []:
        policy = c.get("imagePullPolicy")
        if policy != "IfNotPresent":
            errors.append(f"{pod_name}/{c.get('name')}: imagePullPolicy={policy!r}, expected IfNotPresent")


for pod in pods.get("items", []):
    name = pod["metadata"]["name"]
    spec = pod.get("spec", {})
    check_pull_policies(name, spec.get("containers"))
    check_pull_policies(name, spec.get("initContainers"))

    status = pod.get("status", {})
    for key in ("containerStatuses", "initContainerStatuses", "ephemeralContainerStatuses"):
        for c in status.get(key) or []:
            image = c.get("image", "")
            if image:
                images.append((f"{name}/{c.get('name')}", image))

# The supervisor never runs as its own pod in these flows — it's a binary the
# gateway launches inside the sandbox — so it's verified from the rendered
# config instead of pod status, but held to the same registry-prefix bar
# (which already excludes upstream ghcr.io/nvidia/openshell/* refs).
if supervisor_image:
    images.append(("supervisor_image (gateway config)", supervisor_image))
else:
    errors.append("supervisor_image not found in gateway config configmap — cannot verify provenance")

for source, image in images:
    if not any(image.startswith(prefix) for prefix in allowed):
        errors.append(f"{source}: image {image!r} does not match any allowed registry prefix {allowed}")

if not images:
    errors.append("no images found on pods in namespace — nothing to verify")

if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

print(f"OK: verified {len(images)} image(s) against {len(allowed)} allowed prefix(es)")
PY
