// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Basic sandbox create/exec/delete on an ODH/RHOAI OpenShift deployment.

use openshell_e2e::harness::sandbox::SandboxGuard;

/// Binary path the Kubernetes driver mounts the supervisor at and sets as the
/// sandbox container's command, in both the default `Combined` topology
/// (agent container command overridden to run this binary directly, so it
/// becomes PID 1) and the opt-in `Sidecar` topology (agent container still
/// runs this binary in `--mode=process`). See
/// `crates/openshell-driver-kubernetes/src/driver.rs`
/// (`SUPERVISOR_MOUNT_PATH`/`apply_supervisor_sideload_with_params`).
const SUPERVISOR_BINARY_NAME: &str = "openshell-sandbox";

#[tokio::test]
async fn test_create_delete() {
    let mut sb = SandboxGuard::create(&["--", "echo", "odh-smoke-ok"])
        .await
        .expect("sandbox create should succeed");

    assert!(
        sb.create_output.contains("odh-smoke-ok"),
        "expected 'odh-smoke-ok' in sandbox output:\n{}",
        sb.create_output,
    );

    // PID 1 inside the sandbox is always the supervisor binary — it wraps
    // and supervises the user's process rather than the reverse — so this
    // holds regardless of supervisor topology (Combined vs Sidecar) and
    // regardless of whether the initial command has already exited.
    let cmdline = sb
        .exec(&["cat", "/proc/1/cmdline"])
        .await
        .expect("exec into sandbox to inspect PID 1 should succeed");
    assert!(
        cmdline.contains(SUPERVISOR_BINARY_NAME),
        "expected the supervisor ('{SUPERVISOR_BINARY_NAME}') to be PID 1 in the sandbox, got: {cmdline:?}",
    );

    sb.cleanup().await;
}
