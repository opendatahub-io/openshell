// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

use std::process::Output;

use super::oc::{oc_command, oc_debug_node};

const OPEN_SHELL_EXECUTABLES: &[&str] = &[
    "/opt/openshell/bin/openshell-sandbox",
    "/openshell-sandbox",
    "/openshell-supervisor",
    "/usr/local/bin/openshell-gateway",
];

struct NodeAudit {
    name: String,
    start_date: String,
    start_time: String,
}

/// Collects node-local `SELinux` AVCs for one ODH test scenario.
pub struct SelinuxAudit {
    nodes: Vec<NodeAudit>,
}

impl SelinuxAudit {
    /// Verifies the OpenShift worker-node SELinux prerequisite without starting
    /// an audited scenario.
    pub async fn verify_enforcing() -> Result<Option<()>, String> {
        if !is_openshift().await? {
            return Ok(None);
        }
        let nodes = ready_worker_nodes().await?;
        verify_worker_enforcing(&nodes).await?;
        Ok(Some(()))
    }

    /// Returns `None` outside `OpenShift`, so ordinary tier runs remain usable.
    /// An `OpenShift` cluster that cannot be audited fails the test because that
    /// indicates a missing qualification prerequisite rather than a skip case.
    pub async fn begin() -> Result<Option<Self>, String> {
        if !is_openshift().await? {
            return Ok(None);
        }

        let node_names = ready_worker_nodes().await?;
        verify_worker_enforcing(&node_names).await?;

        let mut audits = Vec::with_capacity(node_names.len());
        for node in node_names {
            let cutoff = oc_debug_node(&node, &["env", "LC_ALL=C", "date", "+%x %X"]).await?;
            let (start_date, start_time) = parse_audit_cutoff(&cutoff)
                .ok_or_else(|| format!("invalid audit cutoff from node/{node}: {cutoff:?}"))?;
            audits.push(NodeAudit {
                name: node.to_string(),
                start_date: start_date.to_string(),
                start_time: start_time.to_string(),
            });
        }
        Ok(Some(Self { nodes: audits }))
    }

    /// Finish the scenario and fail if any `OpenShell` executable emitted an AVC.
    pub async fn finish(self, scenario: &str) -> Result<(), String> {
        let mut failures = Vec::new();
        for node in self.nodes {
            let mut args = vec![
                "sh",
                "-c",
                "start_date=\"$1\"; start_time=\"$2\"; shift 2; for executable in \"$@\"; do output=\"$(LC_ALL=C ausearch -m AVC -ts \"$start_date\" \"$start_time\" -x \"$executable\" -i 2>&1)\"; status=$?; if [ \"$status\" -eq 1 ] && [ \"$output\" = \"<no matches>\" ]; then continue; fi; if [ \"$status\" -ne 0 ]; then echo \"QUERY ERROR for $executable: $output\"; exit \"$status\"; fi; [ -z \"$output\" ] || printf \"AVCs for %s:\\n%s\\n\" \"$executable\" \"$output\"; done",
                "sh",
                &node.start_date,
                &node.start_time,
            ];
            args.extend_from_slice(OPEN_SHELL_EXECUTABLES);
            let output = oc_debug_node(&node.name, &args).await;
            match output {
                Ok(output) if audit_output_is_clean(&output) => {}
                Ok(output) => failures.push(format!("node/{}: {output}", node.name)),
                Err(error) => failures.push(format!("node/{}: {error}", node.name)),
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            Err(format!(
                "{scenario}: OpenShell SELinux audit failed:\n{}",
                failures.join("\n")
            ))
        }
    }
}

async fn is_openshift() -> Result<bool, String> {
    let routes = oc_command()
        .args([
            "api-resources",
            "--api-group=route.openshift.io",
            "--no-headers",
        ])
        .output()
        .await
        .map_err(|error| format!("failed to run oc api-resources: {error}"))?;
    if !routes.status.success() {
        return Err(format!("oc api-resources failed: {}", stderr(&routes)));
    }
    Ok(String::from_utf8_lossy(&routes.stdout)
        .lines()
        .any(|line| line.split_whitespace().next() == Some("routes")))
}

async fn ready_worker_nodes() -> Result<Vec<String>, String> {
    let nodes = oc_command()
        .args([
            "get",
            "nodes",
            "-l",
            "node-role.kubernetes.io/worker",
            "--no-headers",
            "-o",
            "custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type==\"Ready\")].status",
        ])
        .output()
        .await
        .map_err(|error| format!("failed to discover worker nodes: {error}"))?;
    if !nodes.status.success() {
        return Err(format!("oc get worker nodes failed: {}", stderr(&nodes)));
    }
    let node_names = parse_ready_nodes(&String::from_utf8_lossy(&nodes.stdout))
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>();
    if node_names.is_empty() {
        return Err("no Ready worker nodes were returned".to_string());
    }
    Ok(node_names)
}

async fn verify_worker_enforcing(nodes: &[String]) -> Result<(), String> {
    for node in nodes {
        let enforcing = oc_debug_node(node, &["getenforce"]).await?;
        if !parse_selinux_mode(&enforcing) {
            return Err(format!(
                "node/{node} SELinux mode was not exactly Enforcing: {enforcing:?}"
            ));
        }
    }
    Ok(())
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).trim().to_string()
}

fn parse_ready_nodes(output: &str) -> Vec<&str> {
    output
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            match (fields.next(), fields.next()) {
                (Some(name), Some("True")) => Some(name),
                _ => None,
            }
        })
        .collect()
}

fn parse_selinux_mode(output: &str) -> bool {
    output.trim() == "Enforcing"
}

fn parse_audit_cutoff(output: &str) -> Option<(&str, &str)> {
    let (date, time) = output.trim().split_once(' ')?;
    (date.len() == 8 && time.len() == 8).then_some((date, time))
}

fn audit_output_is_clean(output: &str) -> bool {
    output.trim().is_empty()
}

#[cfg(test)]
mod tests {
    use super::{
        Output, audit_output_is_clean, parse_audit_cutoff, parse_ready_nodes, parse_selinux_mode,
    };
    use crate::odh_harness::oc::command_output;
    use std::process::ExitStatus;

    #[test]
    fn parses_ready_nodes_from_oc_custom_columns() {
        assert_eq!(
            parse_ready_nodes("worker-a True\nworker-b False\nworker-c True\n"),
            vec!["worker-a", "worker-c"]
        );
    }

    #[test]
    fn accepts_only_an_enforcing_selinux_mode() {
        assert!(parse_selinux_mode("Enforcing\n"));
        assert!(!parse_selinux_mode("Permissive\n"));
        assert!(!parse_selinux_mode("Enforcing\nextra\n"));
    }

    #[test]
    fn parses_locale_independent_audit_cutoff() {
        assert_eq!(
            parse_audit_cutoff("09/16/26 18:03:04\n"),
            Some(("09/16/26", "18:03:04"))
        );
        assert_eq!(parse_audit_cutoff("09/16/2026 18:03:04"), None);
        assert_eq!(parse_audit_cutoff("09/16/26"), None);
    }

    #[test]
    fn treats_empty_ausearch_output_as_clean_but_reports_avcs() {
        assert!(audit_output_is_clean("\n"));
        assert!(!audit_output_is_clean(
            "type=AVC msg=audit(...): avc: denied"
        ));
    }

    #[test]
    fn preserves_both_streams_for_debug_failures() {
        let output = Output {
            status: ExitStatus::default(),
            stdout: b"QUERY ERROR for /openshell-sandbox: ausearch failed".to_vec(),
            stderr: b"error: non-zero exit code from debug container".to_vec(),
        };
        assert_eq!(
            command_output(&output),
            "stdout: QUERY ERROR for /openshell-sandbox: ausearch failed; stderr: error: non-zero exit code from debug container"
        );
    }
}
