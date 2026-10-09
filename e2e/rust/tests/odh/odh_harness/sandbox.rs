// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Helpers for resolving OpenShell sandbox resources on an ODH cluster.

use serde_json::Value;

use super::oc::oc_json;

/// Returns the pod selector reported by the Sandbox custom resource.
///
/// The sandbox-agent controller owns pod creation and does not propagate the
/// OpenShell sandbox-name label to its pod. The custom resource's status is
/// therefore the stable way for downstream tests to discover that pod.
pub async fn sandbox_pod_selector(namespace: &str, sandbox_name: &str) -> Option<String> {
    let selector = format!("openshell.ai/sandbox-name={sandbox_name}");
    let sandboxes: Value = oc_json(&[
        "get",
        "sandboxes.agents.x-k8s.io",
        "-n",
        namespace,
        "-l",
        &selector,
        "-o",
        "json",
    ])
    .await;
    sandbox_pod_selector_from_json(&sandboxes)
}

fn sandbox_pod_selector_from_json(sandboxes: &Value) -> Option<String> {
    sandboxes
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| (items.len() == 1).then(|| &items[0]))
        .and_then(|sandbox| sandbox["status"]["selector"].as_str())
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::sandbox_pod_selector_from_json;

    #[test]
    fn resolves_selector_from_exactly_one_sandbox() {
        let sandboxes = json!({
            "items": [{"status": {"selector": "agents.x-k8s.io/sandbox-name-hash=abc"}}]
        });

        assert_eq!(
            sandbox_pod_selector_from_json(&sandboxes),
            Some("agents.x-k8s.io/sandbox-name-hash=abc".to_string())
        );
    }

    #[test]
    fn rejects_missing_or_ambiguous_sandboxes() {
        assert_eq!(sandbox_pod_selector_from_json(&json!({"items": []})), None);
        assert_eq!(
            sandbox_pod_selector_from_json(&json!({
                "items": [
                    {"status": {"selector": "one"}},
                    {"status": {"selector": "two"}}
                ]
            })),
            None
        );
    }
}
