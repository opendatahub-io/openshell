// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Helpers for invoking the `oc` CLI from ODH e2e tests.
//!
//! ODH tests shell out to `oc` for cluster-state checks the client doesn't cover
//! (image provenance today; node-level `SELinux` audits next). Centralizing the
//! command construction here keeps every test targeting the same cluster and
//! reporting failures the same way.

use std::process::Stdio;
use std::time::Duration;

use serde_json::Value;
use tokio::io::AsyncWriteExt as _;

/// Maximum duration for one ODH `oc` invocation.
pub const OC_COMMAND_TIMEOUT: Duration = Duration::from_secs(30);

/// Output from an `oc` invocation.
pub struct OcOutput {
    pub success: bool,
    exit_code: Option<i32>,
    stdout: String,
    stderr: String,
}

impl OcOutput {
    pub fn from_output(output: &std::process::Output) -> Self {
        Self {
            success: output.status.success(),
            exit_code: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        }
    }

    /// A safe, allowlisted description for assertion failures.
    ///
    /// Command output may contain Kubernetes objects, credentials, or response
    /// bodies. Keep it available only for parsing and never include it in test
    /// failure output.
    pub fn status_summary(&self) -> String {
        match self.exit_code {
            Some(code) => format!("exit status: {code}"),
            None => "terminated by signal".to_string(),
        }
    }

    /// Returns whether stdout contains an exact, allowlisted result line.
    ///
    /// This permits callers to consume a deliberately emitted protocol marker
    /// without exposing arbitrary command output in diagnostics.
    pub fn has_stdout_line(&self, expected: &str) -> bool {
        self.stdout.lines().any(|line| line.trim() == expected)
    }

    /// Returns whether `oc` identified this request as an API `NotFound`.
    ///
    /// `oc get --raw` writes Kubernetes API errors to stderr. Keep that stream
    /// private so it cannot leak into assertion output, but retain it to
    /// distinguish the expected absence of an API endpoint from real failures.
    pub fn is_not_found(&self) -> bool {
        !self.success && self.stderr.contains("Error from server (NotFound)")
    }

    pub fn json(&self) -> Result<Value, serde_json::Error> {
        serde_json::from_str(&self.stdout)
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
/// Captures command output without emitting it. Retains stdout only for
/// internal parsing; never include command output in test failure messages,
/// since it may contain sensitive cluster data.
pub async fn oc(args: &[&str], input: Option<&str>) -> OcOutput {
    oc_with_timeout(args, input, OC_COMMAND_TIMEOUT).await
}

/// Runs `oc <args>` with an explicit outer command timeout.
///
/// Use this for `oc` subcommands which have their own longer timeout, so the
/// harness does not abort them before their requested deadline. Most callers
/// should use [`oc`], which retains the standard short timeout.
pub async fn oc_with_timeout(
    args: &[&str],
    input: Option<&str>,
    command_timeout: Duration,
) -> OcOutput {
    let mut cmd = oc_command();
    cmd.args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if input.is_some() {
        cmd.stdin(Stdio::piped());
    }
    let output = tokio::time::timeout(command_timeout, async {
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
        child.wait_with_output().await.expect("wait for oc")
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "oc {args:?} timed out after {} seconds",
            command_timeout.as_secs()
        )
    });
    OcOutput::from_output(&output)
}

/// Returns whether the active cluster exposes the `OpenShift` Route API.
///
/// ODH-only tests use this to skip cleanly on non-OpenShift clusters while
/// preserving the standard tier entry points.
pub async fn is_openshift() -> Result<bool, String> {
    let output = oc(&["get", "--raw", "/apis/route.openshift.io/v1"], None).await;
    if output.success {
        return Ok(true);
    }
    if output.is_not_found() {
        return Ok(false);
    }
    Err(format!(
        "unable to determine whether the cluster is OpenShift ({})",
        output.status_summary()
    ))
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
        "oc JSON query failed ({})",
        output.status_summary()
    );
    output
        .json()
        .unwrap_or_else(|_| panic!("oc JSON query returned invalid JSON"))
}

#[cfg(test)]
mod oc_output_tests {
    use super::OcOutput;

    #[test]
    fn status_summary_does_not_include_command_output() {
        let output = OcOutput {
            success: false,
            exit_code: Some(1),
            stdout: "token=secret".to_string(),
            stderr: "Error from server (Forbidden): token=secret".to_string(),
        };

        assert_eq!(output.status_summary(), "exit status: 1");
    }

    #[test]
    fn has_stdout_line_requires_an_exact_line() {
        let output = OcOutput {
            success: true,
            exit_code: Some(0),
            stdout: "prefix\nRESULT\nRESULT-extra".to_string(),
            stderr: String::new(),
        };

        assert!(output.has_stdout_line("RESULT"));
        assert!(!output.has_stdout_line("RESULT-extra-extra"));
    }

    #[test]
    fn recognizes_only_the_oc_not_found_response() {
        let not_found = OcOutput {
            success: false,
            exit_code: Some(1),
            stdout: String::new(),
            stderr:
                "Error from server (NotFound): the server could not find the requested resource"
                    .to_string(),
        };
        let forbidden = OcOutput {
            success: false,
            exit_code: Some(1),
            stdout: String::new(),
            stderr: "Error from server (Forbidden): User cannot get path".to_string(),
        };

        assert!(not_found.is_not_found());
        assert!(!forbidden.is_not_found());
    }
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

/// Read the SELinux label of the supervisor process from its host node.
pub async fn supervisor_selinux_label(namespace: &str, pod: &str) -> Result<String, String> {
    let pod_json = oc_get_json(&["get", "pod", pod, "-n", namespace, "-o", "json"]).await?;
    let (node, pod_uid) = pod_node_and_uid(&pod_json)
        .ok_or_else(|| format!("supervisor Pod {pod:?} has no node name or UID"))?;
    let cgroup_pod_uid = pod_uid_cgroup_form(pod_uid);
    let script = r#"
pod_uid="$1"
cgroup_pod_uid="$2"
found=0
for process in /proc/[0-9]*; do
  executable=$(readlink "$process/exe" 2>/dev/null) || continue
  [ "$executable" = "/openshell-supervisor" ] || continue
  grep -q "pod${pod_uid}" "$process/cgroup" 2>/dev/null ||
    grep -q "pod${cgroup_pod_uid}" "$process/cgroup" 2>/dev/null || continue
  label=
  IFS= read -r label < "$process/attr/current" || true
  printf '%s %s\n' "$executable" "$label"
  found=$((found + 1))
done
[ "$found" -eq 1 ]
"#;
    oc_debug_node(
        node,
        &[
            "sh",
            "-ec",
            script,
            "supervisor-label",
            pod_uid,
            &cgroup_pod_uid,
        ],
    )
    .await
}

pub(crate) fn pod_node_and_uid(value: &Value) -> Option<(&str, &str)> {
    Some((
        value["spec"]["nodeName"].as_str()?,
        value["metadata"]["uid"].as_str()?,
    ))
}

pub(crate) fn pod_uid_cgroup_form(pod_uid: &str) -> String {
    pod_uid.replace('-', "_")
}

/// Run a command in the host namespace of an OpenShift node debug pod.
pub(crate) async fn oc_debug_node(node: &str, args: &[&str]) -> Result<String, String> {
    let output = oc_command()
        .args([
            "debug",
            &format!("node/{node}"),
            "--quiet",
            "--no-stdin",
            "--no-tty",
            "--",
            "chroot",
            "/host",
        ])
        .args(args)
        .output()
        .await
        .map_err(|error| format!("failed to run oc debug node/{node}: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "oc debug node/{node} failed: {}",
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

pub(crate) fn command_output(output: &std::process::Output) -> String {
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

    use super::{
        pod_node_and_uid, pod_uid_cgroup_form, sandbox_id_from_json, supervisor_pod_from_json,
    };

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

    #[test]
    fn extracts_node_and_uid_from_pod() {
        let pod = json!({
            "metadata": {"uid": "123e4567-e89b-12d3-a456-426614174000"},
            "spec": {"nodeName": "worker-a"}
        });

        assert_eq!(
            pod_node_and_uid(&pod),
            Some(("worker-a", "123e4567-e89b-12d3-a456-426614174000"))
        );
    }

    #[test]
    fn formats_pod_uid_for_systemd_cgroup() {
        assert_eq!(
            pod_uid_cgroup_form("123e4567-e89b-12d3-a456-426614174000"),
            "123e4567_e89b_12d3_a456_426614174000"
        );
    }
}
