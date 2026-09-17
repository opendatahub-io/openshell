// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Helpers for invoking the `oc` CLI from ODH e2e tests.
//!
//! ODH tests shell out to `oc` for cluster-state checks the client doesn't cover
//! (image provenance today; node-level `SELinux` audits next). Centralizing the
//! command construction here keeps every test targeting the same cluster and
//! reporting failures the same way.

use std::process::Stdio;

use serde_json::Value;
use tokio::io::AsyncWriteExt as _;

/// Output from an `oc` invocation.
pub struct OcOutput {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
}

impl OcOutput {
    pub fn contains(&self, needle: &str) -> bool {
        self.stdout.contains(needle) || self.stderr.contains(needle)
    }

    pub fn diagnostics(&self) -> String {
        format!("stdout:\n{}\nstderr:\n{}", self.stdout, self.stderr)
    }
}

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

/// Builds a synchronous `oc` command targeting the active e2e cluster.
///
/// This is intended for best-effort cleanup in `Drop` implementations, where
/// an async process cannot be awaited.
pub fn oc_std_command() -> std::process::Command {
    let mut cmd = std::process::Command::new("oc");
    if let Ok(context) = std::env::var("OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE")
        && !context.is_empty()
    {
        cmd.args(["--context", &context]);
    }
    cmd
}

/// Runs `oc <args>`, optionally writing `input` to standard input.
///
/// Returns stdout and stderr even when the command fails, allowing tests to
/// make assertions with the command's diagnostic output.
pub async fn oc(args: &[&str], input: Option<&str>) -> OcOutput {
    let mut cmd = oc_command();
    cmd.args(args).stdout(Stdio::piped()).stderr(Stdio::piped());
    if input.is_some() {
        cmd.stdin(Stdio::piped());
    }
    let mut child = cmd.spawn().expect(
        "failed to run `oc` — required for ODH cluster-state checks; ensure it is in PATH \
         and KUBECONFIG targets the cluster",
    );
    if let Some(input) = input {
        child
            .stdin
            .take()
            .expect("piped stdin")
            .write_all(input.as_bytes())
            .await
            .expect("write manifest to oc");
    }
    let output = child.wait_with_output().await.expect("wait for oc");
    OcOutput {
        success: output.status.success(),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}

/// Returns whether the active cluster exposes the OpenShift Route API.
///
/// ODH-only tests use this to skip cleanly on non-OpenShift clusters while
/// preserving the standard tier entry points.
pub async fn is_openshift() -> bool {
    oc_command()
        .args([
            "api-resources",
            "--api-group=route.openshift.io",
            "--no-headers",
        ])
        .output()
        .await
        .is_ok_and(|output| output.status.success() && !output.stdout.is_empty())
}

/// Runs `oc <args>` and parses stdout as JSON.
///
/// Panics with a descriptive message if `oc` cannot be launched, exits
/// non-zero, or does not return valid JSON — use it for `-o json` queries
/// whose failure should fail the test.
pub async fn oc_json(args: &[&str]) -> Value {
    let output = oc(args, None).await;
    assert!(
        output.success,
        "oc {args:?} failed:\n{}",
        output.diagnostics()
    );
    serde_json::from_str(&output.stdout)
        .unwrap_or_else(|e| panic!("oc {args:?} did not return valid JSON: {e}"))
}
