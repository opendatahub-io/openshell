// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Image provenance verification for downstream `OpenShift` CI.
//!
//! Creates a sandbox, then verifies the images actually running on the
//! cluster: the gateway pod, the supervisor companion pod (the supervisor
//! runs as its own pod created by the Kubernetes driver), and the sandbox
//! pod — all from an authorized downstream registry, and no container has
//! regressed away from imagePullPolicy=IfNotPresent.
//!
//! Requires the `oc` CLI in PATH with a kubeconfig targeting the cluster, and
//! `ALLOWED_IMAGE_REGISTRY_PREFIXES` set to a comma-separated list of allowed
//! registry prefixes (each ending in "/", e.g. "quay.io/opendatahub/") —
//! required with no default, since an empty list would silently approve any
//! image, defeating the check.
//!
//! When the deployment pinned images by digest (`GATEWAY_IMAGE_DIGEST`,
//! `SUPERVISOR_IMAGE_DIGEST`, or `SANDBOX_IMAGE_DIGEST`, or `GATEWAY_IMAGE`,
//! `SUPERVISOR_IMAGE`, or `SANDBOX_IMAGE` set to a
//! `repo@sha256:...` reference, see
//! `odh/scripts/openshell-deploy-from-quay.sh`), the test also verifies that
//! the gateway pod, supervisor companion pod, and sandbox bootstrap container
//! use exactly those digests, so nodes cannot run stale mutable-tag caches. Each
//! running container must retain the requested immutable reference and report
//! a resolved immutable `imageID`. The latter may be a platform-specific
//! manifest selected from the requested multi-architecture image index. Every
//! verified reference and resolved ID is written to
//! `results/e2e-odh-runtime-images.json` as test evidence.

use serde_json::{Value, json};

use openshell_e2e::harness::sandbox::SandboxGuard;

use crate::odh_harness::oc::{oc_command, oc_json};

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

/// Collects (source, image) pairs from a pod list and appends imagePullPolicy
/// violations directly to `errors`. Checks `containers`, `initContainers`,
/// and `ephemeralContainers` alike. Container statuses also add their
/// resolved `imageID` to `evidence`.
fn collect_pod_images(
    pods_json: &Value,
    selector: &str,
    errors: &mut Vec<String>,
    images: &mut Vec<(String, String)>,
    evidence: &mut Vec<Value>,
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
                let source = format!("{name}/{cname}");
                // Match the status entry with the pod-spec image of the same
                // container. Kubernetes does not guarantee that
                // ContainerStatus.image keeps the requested reference form,
                // so the digest assertion uses the spec image while imageID
                // proves the runtime resolved an immutable digest.
                let Some(spec_image) = images
                    .iter()
                    .find(|(recorded, _)| recorded == &source)
                    .map(|(_, image)| image.clone())
                else {
                    errors.push(format!("{source}: no pod-spec image for running container"));
                    continue;
                };
                if let Some(image) = c["image"].as_str() {
                    images.push((source.clone(), image.to_string()));
                }
                evidence.push(json!({
                    "source": source,
                    "image": spec_image,
                    "imageID": c["imageID"].as_str().unwrap_or_default(),
                }));
            }
        }
    }
}

/// Extracts `<key> = "..."` (e.g. `supervisor_image`) from a rendered
/// `gateway.toml`.
fn parse_config_image(gateway_toml: &str, key: &str) -> Option<String> {
    for line in gateway_toml.lines() {
        let Some(rest) = line.trim().strip_prefix(key) else {
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

/// The `sha256:` digest of an image reference such as `repo@sha256:...`.
fn reference_digest(reference: &str) -> Option<&str> {
    reference
        .rsplit_once('@')
        .map(|(_, digest)| digest)
        .filter(|digest| digest.starts_with("sha256:"))
}

/// Digests the deployment pinned, read from the deploy script's image inputs:
/// the component-specific digest input, or a digest reference in its image
/// repository override. Components without a digest keep tag-based provenance
/// checks only.
fn requested_digests() -> Vec<(&'static str, String)> {
    let var = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
    [
        ("gateway", "GATEWAY_IMAGE", Some("GATEWAY_IMAGE_DIGEST")),
        (
            "supervisor",
            "SUPERVISOR_IMAGE",
            Some("SUPERVISOR_IMAGE_DIGEST"),
        ),
        (
            "sandbox runtime",
            "SANDBOX_IMAGE",
            Some("SANDBOX_IMAGE_DIGEST"),
        ),
    ]
    .into_iter()
    .filter_map(|(component, image_var, digest_var)| {
        digest_var
            .and_then(var)
            .or_else(|| {
                var(image_var).and_then(|image| reference_digest(&image).map(str::to_string))
            })
            .map(|digest| (component, digest))
    })
    .collect()
}

/// Whether an image reference or resolved image ID carries `digest`.
fn has_digest(reference: &str, digest: &str) -> bool {
    reference.ends_with(&format!("@{digest}"))
}

/// Returns the observed references for a named runtime container. A status
/// entry is required: a pod spec alone does not establish that the kubelet
/// actually ran the container. The returned reference is the pod-spec image
/// for that container; the resolved image ID comes from the status entry.
fn runtime_container_refs<'a>(
    evidence: &'a [Value],
    container_name: &str,
) -> Vec<(&'a str, Option<&'a str>)> {
    evidence
        .iter()
        .filter(|entry| {
            entry["source"]
                .as_str()
                .and_then(|source| source.rsplit('/').next())
                == Some(container_name)
        })
        .filter_map(|entry| {
            entry["image"]
                .as_str()
                .map(|image| (image, entry["imageID"].as_str().filter(|id| !id.is_empty())))
        })
        .collect()
}

/// Returns true only when every expected running container was requested
/// with the immutable reference and reports a resolved immutable image ID.
///
/// The requested reference comes from the pod spec, which the deployment
/// controls; Kubernetes does not guarantee that ContainerStatus.image keeps
/// that form, so it is not used for the digest assertion. The resolved ID
/// deliberately need not equal `digest`: Kubernetes resolves a
/// multi-architecture OCI index to its platform-specific child manifest
/// before starting the container. Requiring the spec to request the
/// immutable image and a non-empty resolved digest proves the workload was
/// scheduled from the requested image and that the kubelet actually pulled
/// immutable content.
fn runtime_refs_match_digest(refs: &[(&str, Option<&str>)], digest: &str) -> bool {
    !refs.is_empty()
        && refs.iter().all(|(image, image_id)| {
            has_digest(image, digest)
                && image_id.is_some_and(|resolved| reference_digest(resolved).is_some())
        })
}

/// Fails each component whose requested digest is not used by its actual
/// runtime container. The gateway runs in the Helm pod, the sandbox runtime
/// runs as the `openshell-sandbox-bootstrap` init container, and the
/// supervisor runs in its controller-managed companion pod.
fn check_requested_digests(
    gateway_refs: &[(&str, Option<&str>)],
    supervisor_refs: &[(&str, Option<&str>)],
    sandbox_runtime_refs: &[(&str, Option<&str>)],
    errors: &mut Vec<String>,
) {
    for (component, digest) in requested_digests() {
        let matched = match component {
            "gateway" => runtime_refs_match_digest(gateway_refs, &digest),
            "supervisor" => runtime_refs_match_digest(supervisor_refs, &digest),
            _ => runtime_refs_match_digest(sandbox_runtime_refs, &digest),
        };
        if matched {
            println!("{component} image pinned to requested digest {digest}");
        } else {
            errors.push(format!(
                "{component}: requested digest {digest} is not used by the deployed workload"
            ));
        }
    }
}

/// Writes the verified references to an explicit results directory.
fn write_evidence_at(
    results: &std::path::Path,
    evidence: &[Value],
) -> std::io::Result<std::path::PathBuf> {
    let path = results.join("e2e-odh-runtime-images.json");
    let body = serde_json::to_string_pretty(evidence).expect("evidence serializes");
    std::fs::create_dir_all(results)?;
    std::fs::write(&path, body)?;
    Ok(path)
}

/// Resolves the results directory for runtime image evidence. A non-empty
/// `OPENSHELL_E2E_RESULTS_DIR` override places the evidence next to the
/// JUnit reports the entrypoint writes; otherwise fall back to the
/// manifest-relative results directory for direct cargo invocations.
/// Parameters are passed in (rather than read here) so the precedence rules
/// stay testable without mutating the process environment.
fn evidence_results_dir(
    results_override: Option<&str>,
    manifest_dir: Option<&str>,
) -> Result<std::path::PathBuf, String> {
    if let Some(dir) = results_override.filter(|dir| !dir.is_empty()) {
        return Ok(std::path::PathBuf::from(dir));
    }
    let manifest_dir = manifest_dir.ok_or_else(|| {
        "CARGO_MANIFEST_DIR is unset; cannot write runtime image evidence".to_string()
    })?;
    Ok(std::path::Path::new(manifest_dir).join("../../results"))
}

/// Writes the verified references next to the `JUnit` reports. Runtime image
/// digests are required E2E evidence, so inability to persist them fails the
/// test after sandbox cleanup.
fn write_evidence(evidence: &[Value]) -> Result<(), String> {
    let results = evidence_results_dir(
        std::env::var("OPENSHELL_E2E_RESULTS_DIR").ok().as_deref(),
        std::env::var("CARGO_MANIFEST_DIR").ok().as_deref(),
    )?;
    let path = write_evidence_at(&results, evidence).map_err(|err| {
        format!(
            "failed to write runtime image evidence to {}: {err}",
            results.display()
        )
    })?;
    println!("runtime image evidence: {}", path.display());
    Ok(())
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn test_sandbox_gateway_supervisor_images() {
    let namespace = std::env::var("NAMESPACE").unwrap_or_else(|_| "openshell".to_string());
    let release = std::env::var("RELEASE").unwrap_or_else(|_| "openshell".to_string());
    let allowed = allowed_prefixes();

    let mut errors = Vec::new();
    let mut images: Vec<(String, String)> = Vec::new();
    let mut evidence: Vec<Value> = Vec::new();

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
    let sandbox_cr = sandbox_crs
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| items.first());
    let pod_selector = sandbox_cr
        .and_then(|cr| cr["status"]["selector"].as_str())
        .map(str::to_string);
    let sandbox_id = sandbox_cr
        .and_then(|cr| cr["metadata"]["labels"]["openshell.ai/sandbox-id"].as_str())
        .map(str::to_string);

    let sandbox_evidence_start = evidence.len();
    match pod_selector {
        Some(pod_selector) => {
            let sandbox_pods = oc_json(&["get", "pods", "-n", &namespace, "-l", &pod_selector, "-o", "json"]).await;
            collect_pod_images(
                &sandbox_pods,
                &pod_selector,
                &mut errors,
                &mut images,
                &mut evidence,
            );
        }
        None => errors.push(format!(
            "no Sandbox resource with pod selector found for '{sandbox_selector}' — cannot verify image provenance"
        )),
    }
    let sandbox_evidence_end = evidence.len();

    // The Kubernetes driver creates a separate, directly-managed supervisor
    // pod for every sandbox. It is not selected by the external Sandbox CR's
    // controller selector, so query it by the driver's stable labels. Reading
    // its container status is what proves the supervisor image was actually
    // pulled and run, rather than merely rendered into gateway.toml.
    let supervisor_evidence_start = evidence.len();
    match sandbox_id {
        Some(sandbox_id) => {
            let supervisor_selector = format!(
                "openshell.ai/sandbox-id={sandbox_id},openshell.ai/component=supervisor"
            );
            let supervisor_pods = oc_json(&[
                "get",
                "pods",
                "-n",
                &namespace,
                "-l",
                &supervisor_selector,
                "-o",
                "json",
            ])
            .await;
            collect_pod_images(
                &supervisor_pods,
                &supervisor_selector,
                &mut errors,
                &mut images,
                &mut evidence,
            );
        }
        None => errors.push(format!(
            "Sandbox resource for '{sandbox_selector}' has no openshell.ai/sandbox-id label — cannot verify supervisor image provenance"
        )),
    }
    let supervisor_evidence_end = evidence.len();

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
    let gateway_evidence_start = evidence.len();
    collect_pod_images(
        &gateway_pods,
        &gateway_selector,
        &mut errors,
        &mut images,
        &mut evidence,
    );
    let gateway_evidence_end = evidence.len();

    // The rendered config remains useful deployment evidence, while the
    // supervisor pod above provides the authoritative runtime image ID.
    let cm_name = format!("{release}-config");
    let cm_output = oc_command()
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
    let gateway_toml = if cm_output.status.success() {
        String::from_utf8_lossy(&cm_output.stdout).into_owned()
    } else {
        let stderr = String::from_utf8_lossy(&cm_output.stderr);
        errors.push(format!(
            "failed to get gateway config configmap {cm_name}: status {}; stderr: {}",
            cm_output.status,
            stderr.trim()
        ));
        String::new()
    };
    let supervisor_image = if cm_output.status.success() {
        parse_config_image(&gateway_toml, "supervisor_image")
    } else {
        None
    };
    if let Some(image) = &supervisor_image {
        images.push((
            "supervisor_image (gateway config)".to_string(),
            image.clone(),
        ));
    } else if cm_output.status.success() {
        errors.push(
            "supervisor_image not found in gateway config configmap — cannot verify provenance"
                .to_string(),
        );
    }
    // Rendered only when the deployment overrides the sandbox runtime image.
    let sandbox_runtime_image = cm_output
        .status
        .success()
        .then(|| parse_config_image(&gateway_toml, "sandbox_runtime_image"))
        .flatten();
    if let Some(image) = &sandbox_runtime_image {
        images.push((
            "sandbox_runtime_image (gateway config)".to_string(),
            image.clone(),
        ));
    }
    for (source, image) in images
        .iter()
        .filter(|(source, _)| source.contains("gateway config"))
    {
        evidence.push(json!({ "source": source, "image": image, "imageID": "" }));
    }

    let gateway_refs = runtime_container_refs(
        &evidence[gateway_evidence_start..gateway_evidence_end],
        "openshell-gateway",
    );
    let supervisor_refs = runtime_container_refs(
        &evidence[supervisor_evidence_start..supervisor_evidence_end],
        "supervisor",
    );
    let sandbox_runtime_refs = runtime_container_refs(
        &evidence[sandbox_evidence_start..sandbox_evidence_end],
        "openshell-sandbox-bootstrap",
    );
    check_requested_digests(
        &gateway_refs,
        &supervisor_refs,
        &sandbox_runtime_refs,
        &mut errors,
    );

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

    if let Err(err) = write_evidence(&evidence) {
        errors.push(err);
    }
    sb.cleanup().await;

    assert!(
        errors.is_empty(),
        "image provenance check failed:\n{}",
        errors.join("\n")
    );
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::{
        evidence_results_dir, has_digest, parse_config_image, reference_digest,
        runtime_container_refs, runtime_refs_match_digest, write_evidence_at,
    };

    const DIGEST: &str = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    static EVIDENCE_PATH_SEQUENCE: AtomicUsize = AtomicUsize::new(0);

    fn temporary_evidence_path(name: &str) -> std::path::PathBuf {
        let sequence = EVIDENCE_PATH_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "openshell-e2e-evidence-{name}-{}-{sequence}",
            std::process::id()
        ))
    }

    #[test]
    fn parses_config_images_without_matching_longer_keys() {
        let toml = "supervisor_image_pull_policy = \"IfNotPresent\"\n\
                    supervisor_image             = \"quay.io/opendatahub/odh-openshell-supervisor@sha256:aa\"\n\
                    sandbox_runtime_image        = \"quay.io/opendatahub/odh-openshell-sandbox:v1\"\n";
        assert_eq!(
            parse_config_image(toml, "supervisor_image").as_deref(),
            Some("quay.io/opendatahub/odh-openshell-supervisor@sha256:aa")
        );
        assert_eq!(
            parse_config_image(toml, "sandbox_runtime_image").as_deref(),
            Some("quay.io/opendatahub/odh-openshell-sandbox:v1")
        );
        assert_eq!(parse_config_image(toml, "gateway_image"), None);
    }

    #[test]
    fn reads_requested_digests_from_image_references() {
        assert_eq!(
            reference_digest(&format!(
                "quay.io/opendatahub/odh-openshell-supervisor@{DIGEST}"
            )),
            Some(DIGEST)
        );
        assert_eq!(
            reference_digest(&format!("registry.example:5000/ns/sandbox:v1@{DIGEST}")),
            Some(DIGEST)
        );
        assert_eq!(
            reference_digest("quay.io/opendatahub/odh-openshell-sandbox:v1"),
            None
        );
        assert_eq!(
            reference_digest("quay.io/opendatahub/odh-openshell-sandbox"),
            None
        );
        assert_eq!(
            reference_digest("quay.io/opendatahub/odh-openshell-sandbox@md5:abc"),
            None
        );
    }

    #[test]
    fn matches_only_the_exact_requested_digest() {
        assert!(has_digest(
            &format!("quay.io/opendatahub/odh-openshell-gateway@{DIGEST}"),
            DIGEST
        ));
        assert!(!has_digest(
            "quay.io/opendatahub/odh-openshell-gateway:v1",
            DIGEST
        ));
        assert!(!has_digest(
            &format!("quay.io/opendatahub/odh-openshell-gateway@{DIGEST}0"),
            DIGEST
        ));
        assert!(!has_digest(
            &format!(
                "quay.io/opendatahub/odh-openshell-gateway@{}",
                &DIGEST[..20]
            ),
            DIGEST
        ));
    }

    #[test]
    fn requires_requested_reference_and_resolved_runtime_ids() {
        // The first tuple element is the pod-spec image the deployment
        // requested; the second is the runtime-resolved image ID. A
        // multi-architecture index is resolved by Kubernetes to this
        // platform-specific child manifest. It is intentionally different
        // from the requested index digest.
        let requested = format!("quay.io/opendatahub/odh-openshell-gateway@{DIGEST}");
        let resolved_child = "quay.io/opendatahub/odh-openshell-gateway@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let refs = [
            (requested.as_str(), Some(resolved_child)),
            (requested.as_str(), Some(resolved_child)),
        ];
        assert!(runtime_refs_match_digest(&refs, DIGEST));

        let tag_only = [(
            "quay.io/opendatahub/odh-openshell-gateway:pr-98",
            Some(resolved_child),
        )];
        assert!(!runtime_refs_match_digest(&tag_only, DIGEST));

        let missing_resolved_digest = [(requested.as_str(), Some("not-a-digest"))];
        assert!(!runtime_refs_match_digest(&missing_resolved_digest, DIGEST));
        assert!(!runtime_refs_match_digest(&[], DIGEST));

        let missing_id = [(requested.as_str(), None)];
        assert!(!runtime_refs_match_digest(&missing_id, DIGEST));
    }

    #[test]
    fn identifies_and_requires_running_sandbox_and_supervisor_containers() {
        let supervisor_id = format!("quay.io/opendatahub/odh-openshell-supervisor@{DIGEST}");
        let sandbox_id = format!("quay.io/opendatahub/odh-openshell-sandbox@{DIGEST}");
        let evidence = vec![
            serde_json::json!({
                "source": "os-supervisor-example/supervisor",
                "image": format!("quay.io/opendatahub/odh-openshell-supervisor@{DIGEST}"),
                "imageID": supervisor_id,
            }),
            serde_json::json!({
                "source": "example/openshell-sandbox-bootstrap",
                "image": format!("quay.io/opendatahub/odh-openshell-sandbox@{DIGEST}"),
                "imageID": sandbox_id,
            }),
            // A sandbox workload may independently name a container
            // "supervisor". The production check passes only the companion
            // supervisor pod's evidence slice to the helper, so this entry
            // must not influence its requested digest assertion.
            serde_json::json!({
                "source": "example-workload/supervisor",
                "image": "example.invalid/workload:latest",
                "imageID": "example.invalid/workload@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            }),
            serde_json::json!({
                "source": "example/agent",
                "image": "ghcr.io/astral-sh/uv:latest",
                "imageID": "ghcr.io/astral-sh/uv@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            }),
        ];

        let supervisor = runtime_container_refs(&evidence[..1], "supervisor");
        let sandbox = runtime_container_refs(&evidence[1..], "openshell-sandbox-bootstrap");
        assert!(runtime_refs_match_digest(&supervisor, DIGEST));
        assert!(runtime_refs_match_digest(&sandbox, DIGEST));
        assert!(!runtime_refs_match_digest(
            &runtime_container_refs(&evidence, "supervisor"),
            DIGEST
        ));
        assert!(runtime_container_refs(&evidence, "missing").is_empty());
    }

    #[test]
    fn persists_runtime_image_evidence() {
        let results = temporary_evidence_path("writes");
        let path = write_evidence_at(&results, &[serde_json::json!({ "image": "example" })])
            .expect("evidence should be written");

        assert_eq!(
            std::fs::read_to_string(&path).expect("evidence should be readable"),
            "[\n  {\n    \"image\": \"example\"\n  }\n]"
        );
        std::fs::remove_dir_all(results).expect("temporary evidence directory should be removed");
    }

    #[test]
    fn reports_failure_when_evidence_cannot_be_persisted() {
        let blocked_path = temporary_evidence_path("blocked");
        std::fs::write(&blocked_path, "not a directory").expect("test fixture should be created");

        let error = write_evidence_at(&blocked_path, &[])
            .expect_err("a file cannot be used as the evidence directory");
        assert!(
            matches!(
                error.kind(),
                std::io::ErrorKind::AlreadyExists | std::io::ErrorKind::NotADirectory
            ),
            "unexpected evidence write error: {error}"
        );
        std::fs::remove_file(blocked_path).expect("temporary blocker should be removed");
    }

    #[test]
    fn evidence_dir_env_override_takes_precedence() {
        // A non-empty override wins.
        let dir = evidence_results_dir(Some("/tmp/override"), Some("/repo/e2e/rust"))
            .expect("override should win");
        assert_eq!(dir, std::path::PathBuf::from("/tmp/override"));

        // An empty override falls back to the manifest-relative results dir.
        let dir = evidence_results_dir(Some(""), Some("/repo/e2e/rust"))
            .expect("empty override should fall back");
        assert_eq!(
            dir,
            std::path::Path::new("/repo/e2e/rust").join("../../results")
        );

        // No override at all: the same fallback.
        let dir = evidence_results_dir(None, Some("/repo/e2e/rust"))
            .expect("no override should fall back");
        assert_eq!(
            dir,
            std::path::Path::new("/repo/e2e/rust").join("../../results")
        );

        // Neither override nor manifest dir: a clear error.
        let error = evidence_results_dir(None, None).expect_err("manifest dir is required");
        assert!(
            error.contains("CARGO_MANIFEST_DIR"),
            "unexpected error: {error}"
        );
    }
}
