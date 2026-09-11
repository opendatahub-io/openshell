// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Image provenance verification for downstream `OpenShift` CI.
//!
//! Creates a sandbox, then verifies that its image, the gateway's image, and
//! the supervisor image (read from the rendered gateway config — it never
//! runs as its own pod) all came from an authorized downstream registry, and
//! that no container has regressed away from imagePullPolicy=IfNotPresent.
//!
//! Requires the `oc` CLI in PATH with a kubeconfig targeting the cluster, and
//! `ALLOWED_IMAGE_REGISTRY_PREFIXES` set to a comma-separated list of allowed
//! registry prefixes (each ending in "/", e.g. "quay.io/opendatahub/") —
//! required with no default, since an empty list would silently approve any
//! image, defeating the check.

use serde_json::Value;

use openshell_e2e::harness::sandbox::SandboxGuard;

fn allowed_prefixes() -> Vec<String> {
    std::env::var("ALLOWED_IMAGE_REGISTRY_PREFIXES")
        .expect(
            "ALLOWED_IMAGE_REGISTRY_PREFIXES must be set to a comma-separated list of allowed \
             downstream registry prefixes, e.g. \"quay.io/opendatahub/\"",
        )
        .split(',')
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

async fn oc_json(args: &[&str]) -> Value {
    let output = tokio::process::Command::new("oc")
        .args(args)
        .output()
        .await
        .expect(
            "failed to run `oc` — required for image provenance checks; ensure it is in PATH \
             and KUBECONFIG targets the cluster",
        );
    assert!(
        output.status.success(),
        "oc {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|e| panic!("oc {args:?} did not return valid JSON: {e}"))
}

/// Collects (source, image) pairs from a pod list and appends imagePullPolicy
/// violations directly to `errors`. Checks `containers`, `initContainers`,
/// and `ephemeralContainers` alike.
fn collect_pod_images(
    pods_json: &Value,
    selector: &str,
    errors: &mut Vec<String>,
    images: &mut Vec<(String, String)>,
) {
    let items = pods_json
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if items.is_empty() {
        errors.push(format!(
            "no pods found for selector '{selector}' — cannot verify image provenance"
        ));
        return;
    }

    for pod in &items {
        let name = pod["metadata"]["name"].as_str().unwrap_or("<unknown>");
        let spec = &pod["spec"];
        for key in ["containers", "initContainers", "ephemeralContainers"] {
            for c in spec[key].as_array().into_iter().flatten() {
                let cname = c["name"].as_str().unwrap_or("<unknown>");
                let policy = c["imagePullPolicy"].as_str().unwrap_or("<unset>");
                if policy != "IfNotPresent" {
                    errors.push(format!(
                        "{name}/{cname}: imagePullPolicy={policy:?}, expected IfNotPresent"
                    ));
                }
                if let Some(image) = c["image"].as_str() {
                    images.push((format!("{name}/{cname}"), image.to_string()));
                }
            }
        }

        let status = &pod["status"];
        for key in [
            "containerStatuses",
            "initContainerStatuses",
            "ephemeralContainerStatuses",
        ] {
            for c in status[key].as_array().into_iter().flatten() {
                let cname = c["name"].as_str().unwrap_or("<unknown>");
                if let Some(image) = c["image"].as_str() {
                    images.push((format!("{name}/{cname}"), image.to_string()));
                }
            }
        }
    }
}

/// Extracts `supervisor_image = "..."` from a rendered `gateway.toml`.
fn parse_supervisor_image(gateway_toml: &str) -> Option<String> {
    for line in gateway_toml.lines() {
        let Some(rest) = line.trim().strip_prefix("supervisor_image") else {
            continue;
        };
        let Some(rest) = rest.trim_start().strip_prefix('=') else {
            continue;
        };
        let Some(rest) = rest.trim_start().strip_prefix('"') else {
            continue;
        };
        if let Some(end) = rest.find('"') {
            return Some(rest[..end].to_string());
        }
    }
    None
}

#[tokio::test]
async fn test_sandbox_gateway_supervisor_images() {
    let namespace = std::env::var("NAMESPACE").unwrap_or_else(|_| "openshell".to_string());
    let release = std::env::var("RELEASE").unwrap_or_else(|_| "openshell".to_string());
    let allowed = allowed_prefixes();

    let mut errors = Vec::new();
    let mut images: Vec<(String, String)> = Vec::new();

    // A prefix without a trailing "/" would also match a lookalike host, e.g.
    // "registry.redhat.io" matches "registry.redhat.io.attacker.example/image".
    let invalid_prefixes: Vec<&String> = allowed.iter().filter(|p| !p.ends_with('/')).collect();
    if !invalid_prefixes.is_empty() {
        errors.push(format!(
            "allowed registry prefixes must end with '/': {invalid_prefixes:?}"
        ));
    }

    // A bare `echo` exits before the gateway's create-time readiness
    // handshake completes, racing it into reporting "sandbox is not ready"
    // even though the pod itself finishes successfully. A brief sleep avoids
    // the race without depending on a fix to that handshake.
    let mut sb = SandboxGuard::create(&["--", "sh", "-c", "sleep 1 && echo image-provenance-ok"])
        .await
        .expect("sandbox create should succeed");

    // The Kubernetes driver creates a `Sandbox` custom resource
    // (agents.x-k8s.io), not a pod directly — the sandbox-agent controller
    // reconciles that CR into a pod. The CR carries
    // openshell.ai/sandbox-name (see LABEL_SANDBOX_NAME in
    // crates/openshell-core/src/driver_utils.rs — not imported directly
    // since e2e/rust is a standalone crate outside the root workspace), but
    // the controller does not propagate that label onto the pod it creates;
    // the pod only gets a controller-assigned
    // agents.x-k8s.io/sandbox-name-hash label. So look up the CR first and
    // follow its reported `status.selector` to find the pod.
    let sandbox_selector = format!("openshell.ai/sandbox-name={}", sb.name);
    let sandbox_crs = oc_json(&[
        "get",
        "sandboxes.agents.x-k8s.io",
        "-n",
        &namespace,
        "-l",
        &sandbox_selector,
        "-o",
        "json",
    ])
    .await;
    let pod_selector = sandbox_crs
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .and_then(|cr| cr["status"]["selector"].as_str())
        .map(str::to_string);

    match pod_selector {
        Some(pod_selector) => {
            let sandbox_pods = oc_json(&["get", "pods", "-n", &namespace, "-l", &pod_selector, "-o", "json"]).await;
            collect_pod_images(&sandbox_pods, &pod_selector, &mut errors, &mut images);
        }
        None => errors.push(format!(
            "no Sandbox resource with pod selector found for '{sandbox_selector}' — cannot verify image provenance"
        )),
    }

    // Gateway pod.
    let gateway_selector = format!("app.kubernetes.io/instance={release}");
    let gateway_pods = oc_json(&[
        "get",
        "pods",
        "-n",
        &namespace,
        "-l",
        &gateway_selector,
        "-o",
        "json",
    ])
    .await;
    collect_pod_images(&gateway_pods, &gateway_selector, &mut errors, &mut images);

    // Supervisor image — never its own pod, so read it from the rendered
    // gateway config instead. Held to the same registry-prefix bar (which
    // already excludes upstream ghcr.io/nvidia/openshell/* refs).
    let cm_name = format!("{release}-config");
    let cm_output = tokio::process::Command::new("oc")
        .args([
            "get",
            "configmap",
            &cm_name,
            "-n",
            &namespace,
            "-o",
            "jsonpath={.data.gateway\\.toml}",
        ])
        .output()
        .await
        .expect("failed to run oc get configmap");
    let supervisor_image = cm_output
        .status
        .success()
        .then(|| parse_supervisor_image(&String::from_utf8_lossy(&cm_output.stdout)))
        .flatten();
    match supervisor_image {
        Some(image) => images.push(("supervisor_image (gateway config)".to_string(), image)),
        None => errors.push(
            "supervisor_image not found in gateway config configmap — cannot verify provenance"
                .to_string(),
        ),
    }

    for (source, image) in &images {
        if !allowed
            .iter()
            .any(|prefix| image.starts_with(prefix.as_str()))
        {
            errors.push(format!(
                "{source}: image {image:?} does not match any allowed registry prefix {allowed:?}"
            ));
        }
    }

    if images.is_empty() {
        errors.push("no images found — nothing to verify".to_string());
    }

    sb.cleanup().await;

    assert!(
        errors.is_empty(),
        "image provenance check failed:\n{}",
        errors.join("\n")
    );
}
