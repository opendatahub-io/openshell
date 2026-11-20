// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Helpers for resolving `OpenShell` sandbox resources on an ODH cluster.

use serde_json::Value;

use super::oc::oc_json;

/// Returns the pod selector reported by the Sandbox custom resource.
///
/// The sandbox-agent controller owns pod creation and does not propagate the
/// `OpenShell` sandbox-name label to its pod. The custom resource's status is
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
    sandboxes
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .and_then(|sandbox| sandbox["status"]["selector"].as_str())
        .map(str::to_string)
}
