// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Qualification of allocator-assigned identities across managed workspaces.

use std::process::Stdio;
use std::time::Duration;

use openshell_e2e::harness::binary::{openshell_bin, openshell_cmd};
use openshell_e2e::harness::output::strip_ansi;
use openshell_e2e::harness::sandbox::{E2E_WORKLOAD_IMAGE, unique_sandbox_name};
use serde_json::Value;

use crate::odh_harness::oc::{
    is_openshift, oc_command, oc_get_json, paired_supervisor_pod, supervisor_selinux_label,
};
use crate::odh_harness::scc::{Allocation, annotation, categories, check_pod_identity};
use crate::odh_harness::selinux::SelinuxAudit;

const UID_RANGE: &str = "openshift.io/sa.scc.uid-range";
const GROUP_RANGE: &str = "openshift.io/sa.scc.supplemental-groups";
const MCS: &str = "openshift.io/sa.scc.mcs";

async fn cli(args: &[&str]) -> Result<String, String> {
    let output = tokio::time::timeout(
        Duration::from_secs(240),
        openshell_cmd().args(args).kill_on_drop(true).output(),
    )
    .await
    .map_err(|_| format!("CLI timed out: {args:?}"))?
    .map_err(|e| format!("CLI {args:?}: {e}"))?;
    cli_output(&output, args)
}

fn cli_output(output: &std::process::Output, args: &[&str]) -> Result<String, String> {
    if output.status.success() {
        Ok(strip_ansi(&String::from_utf8_lossy(&output.stdout)))
    } else {
        Err(format!(
            "CLI {args:?} failed ({}): {}",
            output.status,
            strip_ansi(&String::from_utf8_lossy(&output.stderr))
        ))
    }
}

// SandboxGuard's cleanup targets the default workspace. This guard carries
// the explicit workspace selector for every operation, including cleanup.
struct WorkspaceSandbox {
    workspace: String,
    sandbox: String,
    cleaned_up: bool,
}

impl WorkspaceSandbox {
    fn new() -> Self {
        let sandbox = unique_sandbox_name();
        Self {
            workspace: format!("scc-{sandbox}"),
            sandbox,
            cleaned_up: false,
        }
    }

    async fn create(&self) -> Result<(), String> {
        cli(&["workspace", "create", "--name", &self.workspace]).await?;
        cli(&[
            "sandbox",
            "create",
            "--workspace",
            &self.workspace,
            "--name",
            &self.sandbox,
            "--from",
            E2E_WORKLOAD_IMAGE,
            "--detach",
        ])
        .await?;
        self.exec("true").await?;
        Ok(())
    }

    async fn namespace_and_pod(&self) -> Result<(Value, Value), String> {
        // Names are unique across test processes. Follow the actual Sandbox
        // resource and controller selector instead of guessing namespace/pod names.
        let selector = format!("openshell.ai/sandbox-name={}", self.sandbox);
        let resources = oc_get_json(&[
            "get",
            "sandboxes.agents.x-k8s.io",
            "-A",
            "-l",
            &selector,
            "-o",
            "json",
        ])
        .await?;
        let sandbox = exactly_one(&resources)?;
        let ns = sandbox["metadata"]["namespace"]
            .as_str()
            .ok_or("Sandbox has no namespace")?;
        let pod_selector = sandbox["status"]["selector"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("Sandbox has no pod selector")?;
        let namespace = oc_get_json(&["get", "namespace", ns, "-o", "json"]).await?;
        if namespace["metadata"]["labels"]["openshell.ai/sandbox-workspace"].as_str()
            != Some(&self.workspace)
            || namespace["metadata"]["labels"]["openshell.ai/managed-by"] != "openshell"
        {
            return Err(format!("{ns}: not this test's managed workspace namespace"));
        }
        let pods =
            oc_get_json(&["get", "pods", "-n", ns, "-l", pod_selector, "-o", "json"]).await?;
        Ok((namespace, exactly_one(&pods)?.clone()))
    }

    async fn exec(&self, script: &str) -> Result<String, String> {
        cli(&[
            "sandbox",
            "exec",
            &self.sandbox,
            "--workspace",
            &self.workspace,
            "--",
            "sh",
            "-ec",
            script,
        ])
        .await
    }

    async fn cleanup(&mut self) -> Result<(), String> {
        cli(&[
            "sandbox",
            "delete",
            &self.sandbox,
            "--workspace",
            &self.workspace,
        ])
        .await?;
        // Sandbox deletion is asynchronous. Wait for gateway state to drain
        // before deleting the logical workspace and its managed namespace.
        for attempt in 0..30 {
            let result = cli(&["workspace", "delete", &self.workspace]).await;
            match result {
                Ok(_) => {
                    // Acceptance of the delete request does not mean the
                    // namespace has finished terminating. Keep Drop's fallback
                    // armed until the test's namespace is actually gone.
                    tokio::time::timeout(Duration::from_secs(120), async {
                        loop {
                            let namespaces = oc_get_json(&[
                                "get",
                                "namespaces",
                                "-l",
                                &self.namespace_selector(),
                                "-o",
                                "json",
                                "--request-timeout=10s",
                            ])
                            .await?;
                            let items = namespaces["items"]
                                .as_array()
                                .ok_or("namespace query returned no items array")?;
                            if items.is_empty() {
                                return Ok::<(), String>(());
                            }
                            tokio::time::sleep(Duration::from_secs(1)).await;
                        }
                    })
                    .await
                    .map_err(|_| format!("namespace cleanup timed out for {}", self.workspace))??;
                    self.cleaned_up = true;
                    return Ok(());
                }
                Err(error) if attempt == 29 => return Err(error),
                Err(_) => tokio::time::sleep(Duration::from_secs(1)).await,
            }
        }
        unreachable!()
    }

    fn namespace_selector(&self) -> String {
        format!(
            "openshell.ai/managed-by=openshell,openshell.ai/sandbox-workspace={}",
            self.workspace
        )
    }
}

impl Drop for WorkspaceSandbox {
    fn drop(&mut self) {
        if self.cleaned_up {
            return;
        }
        // Match the upstream managed-workspace cleanup pattern. Guards exist
        // before creation, so partially created scenarios are cleaned up too.
        for args in [
            vec![
                "sandbox",
                "delete",
                &self.sandbox,
                "--workspace",
                &self.workspace,
            ],
            vec!["workspace", "delete", &self.workspace],
        ] {
            let result = std::process::Command::new(openshell_bin())
                .args(&args)
                .stdout(Stdio::null())
                .status();
            if !result.is_ok_and(|status| status.success()) {
                eprintln!("cleanup CLI {args:?} failed");
            }
        }
        // Only namespaces belonging to this uniquely named test workspace.
        let selector = self.namespace_selector();
        let result = oc_command()
            .args([
                "delete",
                "namespace",
                "-l",
                &selector,
                "--ignore-not-found",
                "--wait=false",
            ])
            .as_std_mut()
            .stdout(Stdio::null())
            .status();
        if !result.is_ok_and(|status| status.success()) {
            eprintln!("cleanup namespace for {} failed", self.workspace);
        }
    }
}

fn exactly_one(list: &Value) -> Result<&Value, String> {
    match list["items"].as_array() {
        Some(items) if items.len() == 1 => Ok(&items[0]),
        Some(items) => {
            let names: Vec<_> = items
                .iter()
                .filter_map(|item| item["metadata"]["name"].as_str())
                .collect();
            Err(format!(
                "expected exactly one matching resource; found {}: {names:?}",
                items.len()
            ))
        }
        None => Err("resource query returned no items array".to_string()),
    }
}

fn managed_phase() -> bool {
    if std::env::var("OPENSHELL_E2E_GATEWAY_MODE").as_deref() != Ok("managed") {
        eprintln!("skipping managed SCC qualification outside a managed phase");
        return false;
    }
    true
}

async fn eligible() -> Result<bool, String> {
    if !managed_phase() {
        return Ok(false);
    }
    if !is_openshift().await? {
        eprintln!("skipping managed SCC qualification outside OpenShift");
        return Ok(false);
    }
    Ok(true)
}

async fn run_scenario(mcs: bool) -> Result<(), String> {
    let mut a = WorkspaceSandbox::new();
    let mut b = WorkspaceSandbox::new();
    let scenario = async {
        a.create().await?;
        b.create().await?;
        if mcs {
            mcs_scenario(&a, &b).await
        } else {
            uid_gid_scenario(&a, &b).await
        }
    }
    .await;
    let cleanup_b = b.cleanup().await;
    let cleanup_a = a.cleanup().await;
    if scenario.is_ok() && cleanup_a.is_ok() && cleanup_b.is_ok() {
        Ok(())
    } else {
        Err(format!(
            "scenario: {scenario:?}; cleanup A: {cleanup_a:?}; cleanup B: {cleanup_b:?}"
        ))
    }
}

async fn uid_gid_scenario(a: &WorkspaceSandbox, b: &WorkspaceSandbox) -> Result<(), String> {
    let mut allocations = Vec::new();
    for sandbox in [a, b] {
        let (namespace, pod) = sandbox.namespace_and_pod().await?;
        let uid = Allocation::parse(annotation(&namespace, UID_RANGE)?)?;
        let gid = Allocation::parse(annotation(&namespace, GROUP_RANGE)?)?;
        eprintln!(
            "workspace {}: namespace={}, UID={uid:?}, GID={gid:?}",
            sandbox.workspace, namespace["metadata"]["name"]
        );
        check_pod_identity(&pod, &uid, &gid)?;
        // Read the workload identity through the public execution path, not
        // merely the desired Kubernetes security context.
        let output = sandbox
            .exec("printf 'SCC_UID='; id -u; printf 'SCC_GID='; id -g; printf 'SCC_GROUPS='; id -G")
            .await?;
        eprintln!("workspace {} runtime identity: {output}", sandbox.workspace);
        for (key, allocation) in [
            ("SCC_UID=", &uid),
            ("SCC_GID=", &gid),
            ("SCC_GROUPS=", &gid),
        ] {
            let values = output
                .lines()
                .find_map(|line| line.strip_prefix(key))
                .filter(|v| !v.trim().is_empty())
                .ok_or_else(|| format!("missing {key} in {output:?}"))?;
            for value in values.split_whitespace() {
                allocation.require(
                    value.parse().map_err(|_| format!("invalid {key}{value}"))?,
                    &sandbox.workspace,
                )?;
            }
        }
        allocations.push((uid, gid));
    }
    allocations[0].0.require_disjoint(&allocations[1].0)?;
    allocations[0].1.require_disjoint(&allocations[1].1)?;
    Ok(())
}

#[tokio::test]
async fn managed_workspaces_use_distinct_uid_gid_allocations() {
    if !eligible()
        .await
        .expect("discover managed OpenShift environment")
    {
        return;
    }
    run_scenario(false)
        .await
        .expect("managed workspace SCC UID/GID isolation");
}

async fn mcs_scenario(a: &WorkspaceSandbox, b: &WorkspaceSandbox) -> Result<(), String> {
    let mut levels = Vec::new();
    for sandbox in [a, b] {
        let (namespace, _) = sandbox.namespace_and_pod().await?;
        let expected = categories(annotation(&namespace, MCS)?)?;
        let output = sandbox
            .exec("printf 'SCC_LABEL='; tr -d '\\000' < /proc/self/attr/current; printf '\\n'")
            .await?;
        let label = output
            .lines()
            .find_map(|line| line.strip_prefix("SCC_LABEL="))
            .ok_or_else(|| format!("missing workload label in {output:?}"))?;
        if categories(label)? != expected {
            return Err(format!(
                "{}: workload label {label:?} differs from namespace MCS {expected:?}",
                sandbox.workspace
            ));
        }
        let ns = namespace["metadata"]["name"]
            .as_str()
            .ok_or("namespace has no name")?;
        let supervisor = paired_supervisor_pod(ns, &sandbox.sandbox).await?;
        let labels = supervisor_selinux_label(ns, &supervisor).await?;
        let label = labels
            .strip_prefix("/openshell-supervisor ")
            .ok_or_else(|| format!("invalid supervisor label {labels:?}"))?;
        eprintln!(
            "workspace {}: namespace={}, MCS={expected:?}, supervisor label={label:?}",
            sandbox.workspace, namespace["metadata"]["name"]
        );
        if categories(label)? != expected {
            return Err(format!(
                "{ns}/{supervisor}: process label {label:?} differs from namespace MCS {expected:?}"
            ));
        }
        levels.push(expected);
    }
    if levels[0] == levels[1] {
        return Err(format!(
            "managed workspaces share MCS categories {:?}",
            levels[0]
        ));
    }
    Ok(())
}

#[tokio::test]
async fn managed_workspaces_use_distinct_process_mcs_categories() {
    if !managed_phase() {
        return;
    }
    let Some(audit) = SelinuxAudit::begin_if_enforcing()
        .await
        .expect("start MCS audit")
    else {
        eprintln!("skipping MCS qualification outside enforcing OpenShift");
        return;
    };
    let scenario = run_scenario(true).await;
    let audit = audit.finish("managed workspace MCS isolation").await;
    assert!(
        scenario.is_ok() && audit.is_ok(),
        "scenario: {scenario:?}; audit: {audit:?}"
    );
}

#[cfg(test)]
mod tests {
    use super::{cli_output, exactly_one};
    use serde_json::json;

    #[test]
    fn successful_cli_output_keeps_warnings_out_of_the_label() {
        let output = std::process::Command::new("sh")
            .args([
                "-c",
                "printf 'SCC_LABEL=system_u:system_r:container_t:s0:c12,c5\\000'; printf 'warning' >&2",
            ])
            .output()
            .unwrap();
        let text = cli_output(&output, &["sandbox", "exec"]).unwrap();
        let label = text.strip_prefix("SCC_LABEL=").unwrap();
        assert_eq!(
            crate::odh_harness::scc::categories(label).unwrap(),
            [5, 12].into_iter().collect()
        );
        assert!(!text.contains("warning"));
    }

    #[test]
    fn failed_cli_output_reports_stderr_without_dumping_stdout() {
        let output = std::process::Command::new("sh")
            .args([
                "-c",
                "printf 'private response'; printf 'request failed' >&2; exit 1",
            ])
            .output()
            .unwrap();
        let error = cli_output(&output, &["workspace", "delete"]).unwrap_err();
        assert!(error.contains("request failed"));
        assert!(!error.contains("private response"));
    }

    #[test]
    fn resource_count_errors_only_report_names() {
        let resource = json!({
            "metadata": {"name": "one", "annotations": {"credential": "private value"}},
            "spec": {"environment": "private value"}
        });
        assert_eq!(
            exactly_one(&json!({"items": [resource.clone()]})).unwrap(),
            &resource
        );
        let error = exactly_one(&json!({
            "items": [resource, {"metadata": {"name": "two"}}]
        }))
        .unwrap_err();
        assert!(error.contains("found 2"));
        assert!(error.contains("one") && error.contains("two"));
        assert!(!error.contains("private value"));
        assert!(exactly_one(&json!({"items": []})).is_err());
        assert!(exactly_one(&json!({"unexpected": "private value"})).is_err());
    }
}
