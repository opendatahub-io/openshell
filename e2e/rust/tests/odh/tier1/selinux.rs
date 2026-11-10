// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! `SELinux` process-label coverage for downstream `OpenShift` runs.

use std::{future::Future, io::Write};

use openshell_e2e::harness::sandbox::SandboxGuard;
use serial_test::serial;
use tempfile::NamedTempFile;

use crate::odh_harness::oc::{paired_supervisor_pod, supervisor_selinux_label};
use crate::odh_harness::selinux::SelinuxAudit;

/// OCP's container `SELinux` type. The complete label includes per-pod MLS/MCS
/// categories, which vary and must not be hard-coded.
const CONTAINER_TYPE: &str = ":container_t:";

async fn run_audited<F, Fut>(scenario: &str, test: F) -> Result<(), String>
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<(), String>>,
{
    let Some(audit) = SelinuxAudit::begin().await? else {
        eprintln!("skipping SELinux-only test outside OpenShift");
        return Ok(());
    };

    let scenario_result = test().await;
    let audit_result = audit.finish(scenario).await;
    combine_results(scenario_result, audit_result)
}

fn combine_results(
    scenario_result: Result<(), String>,
    audit_result: Result<(), String>,
) -> Result<(), String> {
    match (scenario_result, audit_result) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(scenario), Ok(())) | (Ok(()), Err(scenario)) => Err(scenario),
        (Err(scenario), Err(audit)) => Err(format!("{scenario}; {audit}")),
    }
}

#[tokio::test]
async fn selinux_is_enforcing_on_all_worker_nodes() {
    let Some(()) = SelinuxAudit::verify_enforcing()
        .await
        .expect("verify SELinux enforcement on worker nodes")
    else {
        eprintln!("skipping SELinux-only test outside OpenShift");
        return;
    };
}

#[tokio::test]
#[serial(selinux)]
async fn supervisor_runs_in_container_selinux_domain() {
    run_audited("supervisor label", || async {
        let mut sandbox = SandboxGuard::create(&[]).await?;
        let namespace = std::env::var("NAMESPACE").unwrap_or_else(|_| "openshell".to_string());
        let supervisor_pod = paired_supervisor_pod(&namespace, &sandbox.name).await?;
        let label_result = supervisor_selinux_label(&namespace, &supervisor_pod).await;
        sandbox.cleanup().await;
        let label = label_result?;
        for line in label.lines() {
            if !line.contains(CONTAINER_TYPE) {
                return Err(format!(
                    "supervisor Pod {supervisor_pod} reported non-container_t label: {line:?}"
                ));
            }
        }
        Ok(())
    })
    .await
    .expect("SELinux supervisor-label scenario and audit should pass");
}

#[tokio::test]
#[serial(selinux)]
async fn restrictive_filesystem_policy_denies_dev_shm_write() {
    run_audited("filesystem denial", || async {
        let mut policy = NamedTempFile::new().map_err(|error| format!("create policy: {error}"))?;
        policy
            .write_all(
                br"version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /etc, /proc, /dev]
  read_write: [/sandbox, /tmp]
landlock:
  compatibility: hard_requirement
process:
  run_as_user: sandbox
  run_as_group: sandbox
",
            )
            .map_err(|error| format!("write policy: {error}"))?;
        let policy_path = policy.path().to_string_lossy().into_owned();
        let mut sandbox = SandboxGuard::create(&["--policy", &policy_path]).await?;
        let output_result = sandbox.exec(&[
                "sh",
                "-lc",
                "set -eu; test -d /dev/shm; if printf blocked >/dev/shm/openshell-landlock-denied 2>/dev/null; then exit 23; fi; test ! -e /dev/shm/openshell-landlock-denied; echo landlock-denied-ok",
            ])
            .await;
        sandbox.cleanup().await;
        let output = output_result?;
        if !output.contains("landlock-denied-ok") {
            return Err(format!("expected Landlock denial marker in output: {output}"));
        }
        Ok(())
    })
    .await
    .expect("SELinux filesystem-denial scenario and audit should pass");
}

#[test]
fn audited_scenario_keeps_both_failures() {
    let error = combine_results(
        Err("sandbox failed".to_string()),
        Err("AVC detected".to_string()),
    )
    .unwrap_err();
    assert_eq!(error, "sandbox failed; AVC detected");
}
