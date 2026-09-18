// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Helpers for invoking the `oc` CLI from ODH e2e tests.
//!
//! ODH tests shell out to `oc` for cluster-state checks the client doesn't cover
//! (image provenance today; node-level `SELinux` audits next). Centralizing the
//! command construction here keeps every test targeting the same cluster and
//! reporting failures the same way.

use serde_json::Value;

/// Builds an `oc` command targeting the active e2e cluster.
///
/// When `OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE` is set (exported by
/// `e2e/with-kube-gateway.sh`), the context is passed explicitly with
/// `--context`, matching the convention the upstream e2e tests already use for
/// `kubectl`. When it is unset, `oc` falls back to the current kubeconfig
/// context. Callers append the subcommand and its arguments with `.args(...)`.
pub fn oc_command() -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("oc");
    if let Ok(context) = std::env::var("OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE")
        && !context.is_empty()
    {
        cmd.args(["--context", &context]);
    }
    cmd
}

/// Runs `oc <args>` and parses stdout as JSON.
///
/// Panics with a descriptive message if `oc` cannot be launched, exits
/// non-zero, or does not return valid JSON — use it for `-o json` queries
/// whose failure should fail the test.
pub async fn oc_json(args: &[&str]) -> Value {
    let output = oc_command().args(args).output().await.expect(
        "failed to run `oc` — required for ODH cluster-state checks; ensure it is in PATH \
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

/// Resolve the supervisor Pod paired with a named Sandbox resource.
pub async fn paired_supervisor_pod(namespace: &str, sandbox_name: &str) -> Result<String, String> {
    let sandbox_selector = format!("openshell.ai/sandbox-name={sandbox_name}");
    let sandbox = oc_get_json(&[
        "get",
        "sandboxes.agents.x-k8s.io",
        "-n",
        namespace,
        "-l",
        &sandbox_selector,
        "-o",
        "json",
    ])
    .await?;
    let sandbox_id = sandbox_id_from_json(&sandbox)
        .ok_or_else(|| format!("Sandbox {sandbox_name:?} has no openshell.ai/sandbox-id"))?;

    let supervisor_selector =
        format!("openshell.ai/sandbox-id={sandbox_id},openshell.ai/boundary-role=supervisor");
    let pods = oc_get_json(&[
        "get",
        "pods",
        "-n",
        namespace,
        "-l",
        &supervisor_selector,
        "-o",
        "json",
    ])
    .await?;
    supervisor_pod_from_json(&pods)
        .map(str::to_owned)
        .ok_or_else(|| {
            format!(
                "expected exactly one supervisor Pod for Sandbox {sandbox_name:?} ({sandbox_id})"
            )
        })
}

/// Execute a command in a named container and return stdout.
pub async fn oc_exec(
    namespace: &str,
    pod: &str,
    container: &str,
    args: &[&str],
) -> Result<String, String> {
    let mut command = oc_command();
    command
        .args(["exec", pod, "-n", namespace, "-c", container, "--"])
        .args(args);
    let output = command
        .output()
        .await
        .map_err(|error| format!("failed to run oc exec in pod/{pod}: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "oc exec pod/{pod} failed: {}",
            command_output(&output)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

async fn oc_get_json(args: &[&str]) -> Result<Value, String> {
    let output = oc_command()
        .args(args)
        .output()
        .await
        .map_err(|error| format!("failed to run oc {args:?}: {error}"))?;
    if !output.status.success() {
        return Err(format!("oc {args:?} failed: {}", command_output(&output)));
    }
    serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("oc {args:?} returned invalid JSON: {error}"))
}

fn sandbox_id_from_json(value: &Value) -> Option<&str> {
    value
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| (items.len() == 1).then(|| items.first()).flatten())
        .and_then(|sandbox| sandbox["metadata"]["labels"]["openshell.ai/sandbox-id"].as_str())
}

fn supervisor_pod_from_json(value: &Value) -> Option<&str> {
    value
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| (items.len() == 1).then(|| items.first()).flatten())
        .and_then(|pod| pod["metadata"]["name"].as_str())
}

fn command_output(output: &std::process::Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    match (stdout.is_empty(), stderr.is_empty()) {
        (true, true) => "no output".to_string(),
        (false, true) => format!("stdout: {stdout}"),
        (true, false) => format!("stderr: {stderr}"),
        (false, false) => format!("stdout: {stdout}; stderr: {stderr}"),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{sandbox_id_from_json, supervisor_pod_from_json};

    #[test]
    fn resolves_sandbox_id_from_named_sandbox() {
        let sandbox = json!({
            "items": [{
                "metadata": {
                    "labels": {
                        "openshell.ai/sandbox-id": "sandbox-123"
                    }
                }
            }]
        });

        assert_eq!(sandbox_id_from_json(&sandbox), Some("sandbox-123"));
    }

    #[test]
    fn resolves_the_paired_supervisor_pod() {
        let pods = json!({
            "items": [{
                "metadata": {"name": "os-supervisor-sandbox-123"},
                "status": {"phase": "Running"}
            }]
        });

        assert_eq!(
            supervisor_pod_from_json(&pods),
            Some("os-supervisor-sandbox-123")
        );
    }

    #[test]
    fn rejects_missing_or_ambiguous_supervisor_pods() {
        assert_eq!(supervisor_pod_from_json(&json!({"items": []})), None);
        assert_eq!(
            supervisor_pod_from_json(&json!({
                "items": [
                    {"metadata": {"name": "one"}},
                    {"metadata": {"name": "two"}}
                ]
            })),
            None
        );
    }
}
